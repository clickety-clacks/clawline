//
//  PlasmaShader.metal
//  Clawline
//
//  Created by Codex on 1/8/26.
//

#include <metal_stdlib>
using namespace metal;

// Simple test shader to verify Metal integration
[[ stitchable ]] half4 simpleColorShift(
    float2 position,
    half4 color,
    float time
) {
    // Simple color shift based on time
    half shift = half(sin(time) * 0.1);
    return half4(color.r + shift, color.g, color.b, color.a);
}

// Plasma color effect for liquid glass shine
// Uses layered sine waves to create organic flowing patterns

[[ stitchable ]] half4 plasmaEffect(
    float2 position,
    half4 color,
    float time,
    float2 size,
    half4 color1,
    half4 color2,
    half4 color3,
    float intensity,
    float speed,
    float scale
) {
    // Normalize position to 0-1 range
    float2 uv = position / size;

    // Scale the UV coordinates
    float2 scaledUV = uv * scale;

    // Animated time
    float t = time * speed;

    // Classic plasma using multiple sine waves
    float v1 = sin(scaledUV.x * 10.0 + t);
    float v2 = sin(10.0 * (scaledUV.x * sin(t / 2.0) + scaledUV.y * cos(t / 3.0)) + t);

    float cx = scaledUV.x + 0.5 * sin(t / 5.0);
    float cy = scaledUV.y + 0.5 * cos(t / 3.0);
    float v3 = sin(sqrt(100.0 * (cx * cx + cy * cy) + 1.0) + t);

    // Combine waves
    float v = v1 + v2 + v3;

    // Create smooth color transitions
    float plasma1 = sin(v * 3.14159) * 0.5 + 0.5;
    float plasma2 = cos(v * 3.14159) * 0.5 + 0.5;
    float plasma3 = sin(v * 3.14159 + 2.094) * 0.5 + 0.5; // offset by 2*pi/3

    // Blend the three colors based on plasma values
    half4 plasmaColor = color1 * plasma1 + color2 * plasma2 + color3 * plasma3;
    plasmaColor = plasmaColor / (plasma1 + plasma2 + plasma3); // Normalize

    // Mix with original color based on intensity
    // Only affect areas that have some alpha (the glass effect)
    half4 result = mix(color, plasmaColor, half(intensity) * color.a);
    result.a = color.a; // Preserve original alpha

    return result;
}

// Caustics effect - light patterns like sunlight through water
[[ stitchable ]] half4 causticsEffect(
    float2 position,
    half4 color,
    float time,
    float2 size,
    half4 lightColor,
    float intensity,
    float speed,
    float scale
) {
    float2 uv = position / size;
    float2 scaledUV = uv * scale;
    float t = time * speed;

    // Create multiple wave layers at different angles
    float wave1 = sin(scaledUV.x * 12.0 + t) * cos(scaledUV.y * 12.0 + t * 0.7);
    float wave2 = sin((scaledUV.x + scaledUV.y) * 8.0 - t * 0.8) * cos((scaledUV.x - scaledUV.y) * 8.0 + t * 0.6);
    float wave3 = sin(scaledUV.x * 6.0 - t * 1.2) * cos(scaledUV.y * 10.0 + t * 0.5);

    // Combine waves and create sharp bright lines (caustic effect)
    float caustic = wave1 + wave2 + wave3;
    caustic = pow(abs(caustic), 0.5); // Sharp bright lines
    caustic = caustic * 0.5; // Normalize

    // Boost the bright areas
    caustic = pow(caustic, 2.0) * 3.0;
    caustic = clamp(caustic, 0.0, 1.0);

    // Add caustic light to the color
    half4 result = color + lightColor * half(caustic * intensity) * color.a;
    result.a = color.a;

    return clamp(result, 0.0h, 1.0h);
}

// Simpler additive glow variant for subtle shine
[[ stitchable ]] half4 plasmaGlow(
    float2 position,
    half4 color,
    float time,
    float2 size,
    half4 glowColor,
    float intensity,
    float speed,
    float scale
) {
    float2 uv = position / size;
    float2 scaledUV = uv * scale;
    float t = time * speed;

    // Subtle flowing pattern
    float v1 = sin(scaledUV.x * 8.0 + t * 0.5);
    float v2 = cos(scaledUV.y * 6.0 - t * 0.3);
    float v3 = sin((scaledUV.x + scaledUV.y) * 4.0 + t * 0.7);

    float glow = (v1 + v2 + v3) / 6.0 + 0.5; // Normalize to 0-1
    glow = glow * glow; // Square for softer falloff

    // Add glow to original color
    half4 result = color + glowColor * half(glow * intensity) * color.a;
    result.a = color.a;

    return clamp(result, 0.0h, 1.0h);
}

// Fractal noise for subtle grain overlay
float noiseHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);

    float a = noiseHash(i);
    float b = noiseHash(i + float2(1.0, 0.0));
    float c = noiseHash(i + float2(0.0, 1.0));
    float d = noiseHash(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 4; i++) {
        value += amplitude * valueNoise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

[[ stitchable ]] half4 grainNoise(
    float2 position,
    half4 color,
    float time,
    float2 size,
    float intensity,
    float scale
) {
    float2 uv = position / size;
    float baseFrequency = 0.9;
    float n = fbm(uv * scale * baseFrequency + time * 0.02);
    half grain = half(n);
    half4 result = color;
    result.rgb = mix(color.rgb, half3(grain), half(intensity));
    result.a = color.a;
    return result;
}
