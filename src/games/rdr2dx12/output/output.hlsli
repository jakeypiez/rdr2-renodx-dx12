#ifndef SRC_GAMES_RDR2DX12_OUTPUT_HLSLI_
#define SRC_GAMES_RDR2DX12_OUTPUT_HLSLI_

#include "../common.hlsli"

float3 ClampMaxChannel(float3 color) {
  if (RENODX_TONE_MAP_TYPE != 0.f && RENODX_TONE_MAP_TYPE != 1.f && CLAMP_PEAK != 0.f) {
    float peak = RENODX_PEAK_WHITE_NITS;
    float max_channel = max(max(max(color.r, color.g), color.b), peak);
    color *= peak / max_channel;  // Clamp overshoot
  }
  return color;
}

float3 PQEncodeUI(float3 x) {
  x *= (float3)RENODX_GRAPHICS_WHITE_NITS;
  x = ClampMaxChannel(x);
  return EncodePQ(max((float3)0.0, x), 1.f);
}

#endif  // SRC_GAMES_RDR2DX12_OUTPUT_HLSLI_
