// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// Copyright (c) 2021 J. Cuellar

const float INV_PI      = 1. / PI;
const float HALF_PI     = PI / 2.;
const float INV_HALF_PI = 1. / HALF_PI;
const float QRT_PI      = PI / 4.;
const float INV_QRT_PI  = 1. / QRT_PI;
const float PI4         = PI * 4.;
const float INV_PI4     = 1. / PI4;
const float INV_TAU     = 1. / TAU;

const float RAYLEIGH_ZENITH_LENGTH = 8.4e3;
const float MIE_ZENITH_LENGTH = 1.25e3;
const float THREE_OVER_EIGHT_PI = 3.0 / (8.0 * PI);


float clamp_to_unit(float value) {
    return clamp(value, 0.0, 1.0);
}

vec3 clamp_rgb_to_unit(vec3 value) {
    return clamp(value.rgb, 0.0, 1.0);
}

vec3 adjust_contrast(vec3 vec, float level) {
    return mix(vec, vec * vec * vec, level);
}

vec3 apply_photo_tonemap(vec3 color, float exposure, float level) {
    color.rgb *= exposure;
    return mix(color.rgb, 1.0 - exp(-color.rgb), level);
}

float calc_rayleigh_phase(float mu) {
    return THREE_OVER_EIGHT_PI * (1.0 + mu * mu);
}

float calc_mie_phase(float mu, vec3 partial) {
    float denominator = partial.y - partial.z * mu;
    float safe_denominator = max(denominator, 0.0001); // Prevent division by zero on negative powers
    return PI4 * partial.x * pow(safe_denominator, -1.5);
}

// Simplifield for more performance
void calc_simple_optical_depth(float y, out float sr, out float sm, vec2 params) {
    y = max(0.03, y + 0.03) + params.y;
    y = 1.0 / (y * params.x);
    sr = y * RAYLEIGH_ZENITH_LENGTH;
    sm = y * MIE_ZENITH_LENGTH;
}

// Paper based (Unused)
void calc_optical_depth(float y, out float sr, out float sm, vec2 params) {
    y = max(0.0, y);
    y = clamp_to_unit(y * params.x);

    float zenith = acos(y);
    zenith = cos(zenith) + 0.15 * pow(93.885 - ((zenith * 180.0) * INV_PI), -1.253);
    zenith = 1.0 / (zenith + params.y);

    sr = zenith * RAYLEIGH_ZENITH_LENGTH;
    sm = zenith * MIE_ZENITH_LENGTH;
}

// Provides a transformation matrix when passed a vec3.
mat3 create_rotation_matrix(vec3 r) {
    float c1 = cos(r.x), s1 = sin(r.x);
    float c2 = cos(r.y), s2 = sin(r.y);
    float c3 = cos(r.z), s3 = sin(r.z);

    mat3 rotX = mat3(
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, c1, -s1),
        vec3(0.0, s1, c1)
    );

    mat3 rotY = mat3(
        vec3(c2, 0.0, s2),
        vec3(0.0, 1.0, 0.0),
        vec3(-s2, 0.0, c2)
    );

    mat3 rotZ = mat3(
        vec3(c3, -s3, 0.0),
        vec3(s3, c3, 0.0),
        vec3(0.0, 0.0, 1.0)
    );

    return rotZ * rotY * rotX; // Combine rotations in ZYX order
}