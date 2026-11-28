// QWGuard liquid glass backdrop filter.
// Algorithm inspired by Kyant0/AndroidLiquidGlass (Apache-2.0):
// rounded-rect SDF, edge refraction, optional chromatic dispersion.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// The engine fills these two automatically for ImageFilter shaders.
uniform vec2 u_size;
uniform sampler2D u_texture;

uniform float u_radius;
uniform float u_refraction_height;
uniform float u_refraction_amount;
uniform float u_dispersion;
uniform float u_blur;

out vec4 fragColor;

float sdRoundedRect(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - (halfSize - vec2(radius));
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - radius;
}

vec2 gradRoundedRect(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - (halfSize - vec2(radius));
    vec2 s = vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
    if (q.x >= 0.0 || q.y >= 0.0) {
        return s * normalize(max(q, vec2(0.0)) + vec2(1e-5));
    }
    float gx = q.x > q.y ? 1.0 : 0.0;
    return s * vec2(gx, 1.0 - gx);
}

vec4 sampleBlur(vec2 uv) {
    vec2 texel = 1.0 / u_size;
    vec4 c = texture(u_texture, uv) * 2.0;
    c += texture(u_texture, uv + vec2(texel.x * u_blur, 0.0));
    c += texture(u_texture, uv - vec2(texel.x * u_blur, 0.0));
    c += texture(u_texture, uv + vec2(0.0, texel.y * u_blur));
    c += texture(u_texture, uv - vec2(0.0, texel.y * u_blur));
    return c / 6.0;
}

void main() {
    vec2 coord = FlutterFragCoord().xy;
    vec2 halfSize = u_size * 0.5;
    vec2 p = coord - halfSize;

    float sd = sdRoundedRect(p, halfSize, min(u_radius, min(halfSize.x, halfSize.y)));
    if (sd > 0.0) {
        fragColor = texture(u_texture, coord / u_size);
        return;
    }

    // t: 0 at the inner edge of the lens band, 1 on the glass border.
    float t = clamp(1.0 + sd / max(u_refraction_height, 1.0), 0.0, 1.0);
    float d = (1.0 - sqrt(max(1.0 - t * t, 0.0))) * u_refraction_amount;
    vec2 grad = gradRoundedRect(p, halfSize, min(u_radius * 1.5, min(halfSize.x, halfSize.y)));
    vec2 offset = d * grad;
    vec2 uv = clamp((coord + offset) / u_size, vec2(0.0), vec2(1.0));

    vec4 color = sampleBlur(uv);

    // Chromatic dispersion is strongest around the diagonal corners,
    // matching the reference's (x*y)/(halfW*halfH) falloff.
    if (u_dispersion > 0.001 && t > 0.15) {
        float corner = (p.x * p.y) / max(halfSize.x * halfSize.y, 1.0);
        float k = u_dispersion * corner * t;
        vec2 disp = normalize(grad + vec2(1e-5)) * (d * k);
        vec4 red = texture(u_texture, clamp(uv + disp / u_size, vec2(0.0), vec2(1.0)));
        vec4 blue = texture(u_texture, clamp(uv - disp / u_size, vec2(0.0), vec2(1.0)));
        color.r = mix(color.r, red.r, 0.35 * abs(k));
        color.b = mix(color.b, blue.b, 0.30 * abs(k));
    }

    fragColor = color;
}
