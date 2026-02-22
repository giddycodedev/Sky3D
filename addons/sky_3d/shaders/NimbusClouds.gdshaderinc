//
// Nimbus Clouds - Volumetric Cloud Shader
//------------------------------------------------------------------------------
//
// Implementation exercise inspired by public talks and papers on real-time
// volumetric clouds (Beer–Lambert extinction, single scattering, phase functions,
// Beer–Powder approximation, and multi-octave scattering tricks).
//
// Primary inspiration:
//
// YouTube video (visual target + implementation walkthrough)
// https://www.youtube.com/watch?v=Qj_tK_mdRcA
//
// Key technical references used while implementing the shader
// The Real-time Volumetric Cloudscapes of Horizon Zero Dawn (Guerrilla Games)
// Beer–Powder approximation and cloud lighting intuition (PDF).
//
// Frostbite / EA volumetric cloud material
// Practical implementation details and tuning guidance (PPTX).
//

group_uniforms nimbus_clouds;
// Basic uniforms
uniform bool nimbus_visible = true;
uniform float nimbus_wind_speed : hint_range(0.0, 320.0, 0.01) = 0.0;
uniform vec3  nimbus_wind_direction = vec3(0.0, 0.0, 0.0);
uniform vec3 nimbus_color = vec3(1.0, 1.0, 1.0);
uniform sampler3D nimbus_texture : filter_linear, repeat_enable;
uniform float nimbus_layer_altitude = 8000.0;
uniform float nimbus_layer_thickness = 2000.0;
uniform float nimbus_layer_max_distance = 50000.0;
uniform float nimbus_planet_radius = 6371000.0;

// Marching and iteration limits for better performance
uniform int nimbus_steps : hint_range(8, 128, 1) = 16; // SDF sphere-trace steps (enter/exit search), not volume steps
uniform int nimbus_volume_steps : hint_range(8, 128, 1) = 16; // Direct number of view samples through the inside segment.
uniform int nimbus_light_steps : hint_range(4, 16, 1) = 8; // How many samples along the light ray (per view sample).
uniform int nimbus_scattering_octaves : hint_range(2, 8, 1) = 4; // Multi scatter octave count.

// How fast the medium eats light per unit distance (scaled by density).
// LOW  -> light penetrates deeper, cube looks more transparent.
// HIGH -> light dies quickly, cube becomes milky/opaque and can saturate to solid.
uniform float nimbus_absorption : hint_range(0.0005, 0.05, 0.0005) = 0.01; // Beer–Lambert extinction coefficient

// How much stuff is in the cloud (independent of absorption).
// LOW  -> less material, more transparent.
// HIGH -> more material, more opaque (because optical depth increases).
// Density multiplies with absorption inside Beer’s law, so both together control opacity.
uniform float nimbus_density_scale : hint_range(0.0, 8.0, 0.01) = 1.0; // Overall density multiplier

uniform float nimbus_light_intensity : hint_range(0.0, 8.0, 0.01) = 1.0; // Single-scatter brightness (C)
uniform float nimbus_beer_powder_strength : hint_range(0.0, 1.0, 0.01) = 0.5; // 0=off, 1=standard boost
uniform float nimbus_ms_attenuation : hint_range(0.1, 1.0, 0.01) = 0.1; // How fast extinction drops per octave
uniform float nimbus_ms_contribution : hint_range(0.1, 1.0, 0.01) = 0.6; // How much each octave contributes
uniform float nimbus_ms_phase_attenuation : hint_range(0.1, 1.0, 0.01) = 0.1; // How fast g/phase weakens per octave

// 3D noise shaping
uniform float nimbus_noise_scale : hint_range(0.0001, 0.1, 0.0001) = 0.035; // texture frequency
uniform float nimbus_noise_coverage : hint_range(0.0, 1.0, 0.01) = 0.35; // higher = fewer dense regions
uniform float nimbus_noise_power : hint_range(0.5, 8.0, 0.01) = 2.0; // contrast / puffiness

// Sky coverage and noise distribution
uniform float nimbus_zenith_scale  : hint_range(0.0, 1.0, 0.0001) = 0.3;
uniform float nimbus_horizon_scale : hint_range(0.0, 1.0, 0.0001) = 0.015;
uniform float nimbus_horizon_start : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform float nimbus_horizon_end   : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float nimbus_horizon_density_mul   : hint_range(0.1, 1.0, 0.01) = 0.35; // 1=no thinning, lower=thinner horizon
uniform float nimbus_horizon_light_mul : hint_range(0.1, 1.0, 0.01) = 0.75;
uniform sampler2D nimbus_coverage_tex : source_color, filter_linear, repeat_enable;
uniform float nimbus_coverage_tex_scale : hint_range(0.0, 20.0, 0.01) = 3.4; // blob size
uniform float nimbus_coverage_strength : hint_range(0.0, 1.0, 0.01) = 0.1; // 0=no effect, 1=strong
uniform float nimbus_coverage_bias : hint_range(-0.5, 0.5, 0.01) = -0.10; // negative => more sky
uniform float nimbus_coverage_horizon_boost : hint_range(0.0, 0.5, 0.01) = 0.20; // fewer clouds near horizon
uniform float nimbus_edge_breakup_strength : hint_range(0.0, 1.0, 0.01) = 0.35; // 0=off
uniform float nimbus_edge_breakup_shift    : hint_range(0.0, 0.25, 0.01) = 0.06; // Raises threshold only near edges
uniform float nimbus_edge_haze_strength : hint_range(0.0, 1.0, 0.01) = 0.1; // 0=off

group_uniforms nimbus_debug;
uniform bool nimbus_debug_layer = false;
uniform int nimbus_debug_mode = 0;

const int SDF_MAX_STEPS = 128;
const float SDF_EPSILON = 0.5;
const int VOL_MAX_STEPS = 128;
const int LIGHT_MAX_STEPS = 16;
const int MAX_SCATTERING_OCTAVES  = 8;


// Nimbus formulas
//------------------------------------------------------------------------------
float phase_henyey_greenstein(float mu, float g) {
    float gg = g * g;
    float denom = pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5);
    // We do not use normalized HG phase function (4π normalization).
    //return (1.0 - gg) / (4.0 * PI * denom);
    // We use unnormalized so phase ≈ 1 scale and doesn't require retuning intensities.
    return (1.0 - gg) / denom;
}

float nimbus_multi_octave_scattering(float tauL, float mu) {
    float a = 1.0;
    float b = 1.0;
    float c = 1.0;
    float lum = 0.0;

    int oct = clamp(nimbus_scattering_octaves, 1, 8);

    for (int i = 0; i < 8; ++i) {
        if (i >= oct) break;

        float g_scaled = 0.3 * c;
        float phase = phase_henyey_greenstein(mu, g_scaled);
        float beers = exp(-tauL * a); // Beer only (no powder here)

        lum += b * phase * beers;

        a *= nimbus_ms_attenuation;
        b *= nimbus_ms_contribution;
        c *= (1.0 - nimbus_ms_phase_attenuation);
    }

    return lum;
}

float beer_powder(float tau, float strength) {
    // Powdered sugar boost (Guerrilla-style), brighten near-surface/creases.
    // tau = optical depth along the LIGHT ray to this point.
    // strength scales how much of the powder term we apply.
    float beer = exp(-tau);
    float powder = 1.0 - exp(-2.0 * tau); // k = 2
    return mix(beer, powder, clamp(strength, 0.0, 1.0));
}

float nimbus_noise_field(vec3 p) {
    // Single 3D texture sample, tiled via repeat_enable.
    vec3 uvw = p * nimbus_noise_scale * 0.001 + nimbus_wind_direction * (TIME * nimbus_wind_speed);
    
    float n = texture(nimbus_texture, uvw).r;
    n = smoothstep(nimbus_noise_coverage, 1.0, n); // Decide what survives
    n = pow(clamp(n, 0.0, 1.0), nimbus_noise_power); // Sharpen / soften

    return n;
}

vec2 nimbus_octa_encode(vec3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z) + 1e-6);
    vec2 uv = n.xz;
    if (n.y < 0.0) {
        uv = (1.0 - abs(uv.yx)) * sign(uv);
    }
    return uv * 0.5 + 0.5; // [0..1]
}