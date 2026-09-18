#ifndef SRC_GAMES_RDR2DX12_COMMON_HLSLI_
#define SRC_GAMES_RDR2DX12_COMMON_HLSLI_

#include "./perceptual_color.hlsli"
#include "./shared.h"

// HLSL port of reference/rdr2vk/common.glsl; injection macros belong to shared.h.
// GLSL boolean mix is selection, not interpolation: an unselected NaN must
// not contaminate the selected component. Scalar conditions also work in HLSL 2021.
float3 RDR2Select(float3 a, float3 b, bool3 condition) {
  return float3(condition.x ? b.x : a.x,
                condition.y ? b.y : a.y,
                condition.z ? b.z : a.z);
}

// START INCLUDES
float3 EncodeRDR2Gamma(float3 color_linear) {
  float curve_gamma = 2.2;
  float curve_toe_threshold = 0.0031308;
  float curve_power = 1.0 / curve_gamma;
  float curve_offset = 0.055 * (curve_gamma - 1.0) / (2.4 - 1.0);  // Observed: 0.0471429
  float curve_scale = 1.0 + curve_offset;  // Observed: 1.0471429
  float curve_toe_slope = (pow(curve_toe_threshold, curve_power) * curve_scale - curve_offset) / curve_toe_threshold;  // Observed: 9.2649536

  return RDR2Select(
      (pow(color_linear, (float3)curve_power) * curve_scale) - (float3)curve_offset,
      color_linear * curve_toe_slope,
      color_linear < (float3)curve_toe_threshold);
}

float3 DecodeRDR2Gamma(float3 color_encoded) {
  float curve_gamma = 2.2;
  float curve_toe_threshold = 0.0031308;
  float curve_power = 1.0 / curve_gamma;
  float curve_offset = 0.055 * (curve_gamma - 1.0) / (2.4 - 1.0);
  float curve_scale = 1.0 + curve_offset;
  float curve_toe_slope = (pow(curve_toe_threshold, curve_power) * curve_scale - curve_offset) / curve_toe_threshold;
  float encoded_toe_threshold = curve_toe_threshold * curve_toe_slope;  // Approximately 0.0290067

  return RDR2Select(
      pow((color_encoded + (float3)curve_offset) / curve_scale, (float3)curve_gamma),
      color_encoded / curve_toe_slope,
      color_encoded < (float3)encoded_toe_threshold);
}

// --- sRGB ENCODING ---
float EncodeSRGB(float x) {
  return lerp(
      x * 12.92,
      1.055 * pow(x, 1.0 / 2.4) - 0.055,
      step(0.0031308, x));
}

float3 EncodeSRGB(float3 x) {
  return lerp(
      x * 12.92,
      1.055 * pow(x, (float3)(1.0 / 2.4)) - 0.055,
      step((float3)0.0031308, x));
}

// --- sRGB DECODING ---
float DecodeSRGB(float x) {
  return lerp(
      x / 12.92,
      pow((x + 0.055) / 1.055, 2.4),
      step(0.04045, x));
}

float3 DecodeSRGB(float3 x) {
  return lerp(
      x / 12.92,
      pow((x + 0.055) / 1.055, (float3)2.4),
      step((float3)0.04045, x));
}

// --- GAMMA ENCODING ---
float EncodeGamma(float x, float gamma) {
  return pow(x, 1.0 / gamma);
}

float3 EncodeGamma(float3 x, float gamma) {
  return pow(x, (float3)(1.0 / gamma));
}

// --- GAMMA DECODING ---
float DecodeGamma(float x, float gamma) {
  return pow(x, gamma);
}

float3 DecodeGamma(float3 x, float gamma) {
  return pow(x, (float3)gamma);
}

// Fix or undo gamma mismatch by converting between sRGB and gamma 2.2
float CorrectGammaMismatch(float x, bool inverse) {
  return inverse
             ? DecodeSRGB(EncodeGamma(x, 2.2))   // undo fix
             : DecodeGamma(EncodeSRGB(x), 2.2);  // apply fix
}

float3 CorrectGammaMismatch(float3 x, bool inverse) {
  float3 s = sign(x);
  float3 a = abs(x);

  float3 result = inverse
                    ? DecodeSRGB(EncodeGamma(a, 2.2))
                    : DecodeGamma(EncodeSRGB(a), 2.2);

  return s * result;
}

float3 GammaSafe(float3 x) {
  if (RENODX_SDR_EOTF_EMULATION != 0.f && RENODX_TONE_MAP_TYPE != 1.f) {
    return CorrectGammaMismatch(x, false);
  } else {
    return x;
  }
}

float3 GammaSafe(float3 x, bool inverse) {
  if (RENODX_SDR_EOTF_EMULATION != 0.f && RENODX_TONE_MAP_TYPE != 1.f) {
    return CorrectGammaMismatch(x, inverse);
  } else {
    return x;
  }
}

// The GLSL constructor's columns are stored here as HLSL literal ROWS.
// These matrices are transposed relative to GLSL: M * v becomes mul(v, M).
// This is an algebraic convention, independent of row_major/column_major packing.
static const float3x3 BT709_TO_BT2020_MAT = float3x3(
    float3(0.6274039149284363, 0.06909728795289993, 0.0163914393633604),
    float3(0.3292830288410187, 0.9195404052734375, 0.08801330626010895),
    float3(0.04331306740641594, 0.01136231515556574, 0.8955952525138855));

static const float3x3 BT2020_TO_BT709_MAT = float3x3(
    float3(1.6604909896850586, -0.12455047667026520, -0.01815076358616352),
    float3(-0.5876411199569702, 1.1328998804092407, -0.10057889670133591),
    float3(-0.07284986227750778, -0.00834942236542702, 1.1187297105789185));

float3 BT2020FromBT709(float3 bt709) {
  return mul(bt709, BT709_TO_BT2020_MAT);
}

float3 BT709FromBT2020(float3 bt2020) {
  return mul(bt2020, BT2020_TO_BT709_MAT);
}

float3 EncodePQ(float3 color, float scaling) {
  float M1 = 2610.f / 16384.f;           // 0.1593017578125f;
  float M2 = 128.f * (2523.f / 4096.f);  // 78.84375f;
  float C1 = 3424.f / 4096.f;            // 0.8359375f;
  float C2 = 32.f * (2413.f / 4096.f);   // 18.8515625f;
  float C3 = 32.f * (2392.f / 4096.f);   // 18.6875f;
  color *= (scaling / 10000.f);
  float3 y_m1 = pow(color, (float3)M1);
  return pow(((float3)C1 + (float3)C2 * y_m1) / (1.f + (float3)C3 * y_m1), (float3)M2);
}
float3 EncodePQ(float3 color) {
  return EncodePQ(color, 10000.f);
}

float3 DecodePQ(float3 in_color, float scaling) {
  float M1 = 2610.f / 16384.f;           // 0.1593017578125f;
  float M2 = 128.f * (2523.f / 4096.f);  // 78.84375f;
  float C1 = 3424.f / 4096.f;            // 0.8359375f;
  float C2 = 32.f * (2413.f / 4096.f);   // 18.8515625f;
  float C3 = 32.f * (2392.f / 4096.f);   // 18.6875f;

  float3 e_m12 = pow(in_color, 1.f / (float3)M2);
  float3 out_color = pow(max(e_m12 - (float3)C1, 0) / ((float3)C2 - (float3)C3 * e_m12),
                        1.f / (float3)M1);
  return out_color * (10000.f / scaling);
}
float3 DecodePQ(float3 color) {
  return DecodePQ(color, 10000.f);
}

// Safe divide (float & vec2 versions)
float DivideSafe(float a, float b, float fallback) {
  return (b == 0.0) ? fallback : a / b;
}
float DivideSafe(float a, float b) {
  return DivideSafe(a, b, 3.4028235e38);
}
float2 DivideSafe(float2 a, float2 b, float2 fallback) {
  return float2(DivideSafe(a.x, b.x, fallback.x), DivideSafe(a.y, b.y, fallback.y));
}
float2 DivideSafe(float2 a, float2 b) {
  return DivideSafe(a, b, (float2)3.4028235e38);
}
float3 DivideSafe(float3 a, float3 b, float3 fallback) {
  return float3(DivideSafe(a.x, b.x, fallback.x), DivideSafe(a.y, b.y, fallback.y), DivideSafe(a.z, b.z, fallback.z));
}

// END INCLUDES

#endif  // SRC_GAMES_RDR2DX12_COMMON_HLSLI_
