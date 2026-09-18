/*
 * DX12 replacement for shader 0x1096351C (ps_5_1) — HDR output / PQ encode pass.
 * DX12 counterpart of the Vulkan mod's output shader 0x14BF23D4.
 *
 * Derived from the game's own DX12 bytecode (not translated from Vulkan source):
 * the two differ, e.g. this shader has no separate alpha-texture sample.
 *
 * Bindings must match the original exactly — verified with D3DDisassemble:
 *   cbuffer cb22[11] @ b22   cbuffer cb23[5] @ b23
 *   SamplerState @ s2, s5     StructuredBuffer<>, stride 92 @ t0
 *   Texture2D @ t32           Texture3D @ t35
 *   in: SV_Position + TEXCOORD0.xy    out: SV_Target0
 *
 * The only behavioural change is inside the `if (cb22[9].y != 0)` block: when a
 * RenoDX tone mapper is active, PQ encoding is driven by RENODX_GRAPHICS_WHITE_NITS
 * (RenoDX's UI brightness control) instead of the game's cb23[0].x / cb23[3].w
 * factors. With the tone mapper set to Vanilla the arithmetic reduces to exactly
 * the original expression, so the off state is bit-identical.
 */
#include "../shared.h"
#include "../output/output.hlsli"

struct CalibrationData {
  float4 m0;  // byte 0  (m0.w at byte 12 is read)
  int4 m1;
  float4 m2;
  int4 m3;
  int m4;
  int m5;
  int m6;
  int m7;
  int m8;
  uint m9;
  float m10;
};  // 92 bytes, matching the declared structured stride

StructuredBuffer<CalibrationData> calibration : register(t0, space0);
Texture2D<float4> color_texture : register(t32, space0);
Texture3D<float4> tonemap_lut : register(t35, space0);
SamplerState lut_sampler : register(s2, space0);
SamplerState color_sampler : register(s5, space0);

cbuffer cb22 : register(b22, space0) {
  float4 cb22[11];
};

cbuffer cb23 : register(b23, space0) {
  float4 cb23[5];
};

float4 main(float4 position : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target0 {
  float4 color = color_texture.Sample(color_sampler, texcoord);
  color = color * cb22[8] + cb22[7];

  // Optional tonemap-3D LUT lookup
  if (cb22[10].x != 0.0f) {
    color.xyz = tonemap_lut.SampleLevel(lut_sampler, color.xyz, 0).xyz;
  }

  // Optional BT.709 -> BT.2020 conversion followed by PQ encode
  if (cb22[9].y != 0.0f) {
    float3 bt2020 = float3(
        dot(float3(0.6274039745330810546875f, 0.329281985759735107421875f, 0.043313600122928619384765625f), color.xyz),
        dot(float3(0.06909699738025665283203125f, 0.919539988040924072265625f, 0.0113612003624439239501953125f), color.xyz),
        dot(float3(0.01639159955084323883056640625f, 0.0880132019519805908203125f, 0.895595014095306396484375f), color.xyz));

    if (RENODX_TONE_MAP_TYPE != 0.f) {
      // RenoDX drives the nits scaling rather than the game's UI-brightness factors.
      color.xyz = PQEncodeUI(bt2020);
    } else {
      // Vanilla: EncodePQ() with the default 10000-nit scaling divides back out,
      // so this is exactly the game's per-channel expression.
      float3 scaled = bt2020 * cb23[0].x / cb23[3].w;
      color.xyz = EncodePQ(scaled);
    }
  }

  // Alpha premultiply toggle
  float3 premultiplied = color.xyz * color.w;
  color.xyz = (cb22[9].x == 0.0f) ? color.xyz : premultiplied;

  // Calibration: squared alpha when the calibration value differs from 1
  float calibration_alpha = calibration[0].m0.w;
  float alpha_scaled = color.w * calibration_alpha;
  float alpha_squared = alpha_scaled * alpha_scaled;
  color.z = (calibration_alpha != 1.0f) ? alpha_squared : color.xyz.z;

  float calibration_x = calibration[0].m0.x;
  color.w = color.w * calibration_x;

  // Vignette
  if (cb22[10].y != 0.0f) {
    float v = color.w * cb22[9].z;
    color.w = (cb22[9].z != 0.0f) ? v : color.w;

    if (cb22[9].w != 0.0f) {
      color.w = -0.5f * (cos(color.w * 3.1415927410125732421875f) - 1.0f);
    }
  }

  color.w = saturate(color.w);
  return color;
}
