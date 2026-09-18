// Reconstruction of DX12 shader 0x1096351C (ps_5_1) — the HDR output / PQ encode pass.
//
// This is the DX12 counterpart of the Vulkan mod's output shader 0x14BF23D4.
// Reconstructed from the shader's own DX12 disassembly, NOT translated from the
// Vulkan source, because the two differ (e.g. this shader has no separate alpha
// texture sample that the Vulkan version performs).
//
// Bindings must match the original exactly (verified against D3DDisassemble):
//   dcl_constantbuffer CB0[22][22][11]  space=0   -> cbuffer cb0[11] @ b22
//   dcl_constantbuffer CB1[23][23][5]   space=0   -> cbuffer cb1[5]  @ b23
//   dcl_sampler S0[2:2]  space=0                  -> SamplerState @ s2
//   dcl_sampler S1[5:5]  space=0                  -> SamplerState @ s5
//   dcl_resource_structured T0[0:0], 92  space=0  -> StructuredBuffer, stride 92
//   dcl_resource_texture2d  T1[32:32] space=0     -> Texture2D   @ t32
//   dcl_resource_texture3d  T2[35:35] space=0     -> Texture3D   @ t35
//   input  v1.xy (TEXCOORD0), output o0.xyzw (SV_Target0)
//
// Original disassembly (key operations):
//   sample   r0.xyzw, v1.xyxx, T1[32].xyzw, S1[5]
//   mad      r0.xyzw, r0.xyzw, CB0[22][8].xyzw, CB0[22][7].xyzw
//   if_nz    CB0[22][10].x          -> tonemap-3D LUT sample
//   if_nz    CB0[22][9].y           -> BT.709->BT.2020 + PQ encode
//   eq/mul/movc r0.xyz              -> alpha premultiply toggle (CB0[22][9].x)
//   ld_structured ... T0[0] offsets 0 and 12 -> calibration values
//   sincos-based vignette, movc_sat clamp

struct CalibrationData {
  float4 m0;  // byte 0   (m0.w at byte 12 is used)
  int4 m1;    // byte 16
  float4 m2;  // byte 32
  int4 m3;    // byte 48
  int m4;     // byte 64
  int m5;     // byte 68
  int m6;     // byte 72
  int m7;     // byte 76
  int m8;     // byte 80
  uint m9;    // byte 84
  float m10;  // byte 88
};            // 92 bytes total, matching the declared structured stride

StructuredBuffer<CalibrationData> calibration : register(t0, space0);
Texture2D<float4> color_texture : register(t32, space0);
Texture3D<float4> tonemap_lut : register(t35, space0);
SamplerState lut_sampler : register(s2, space0);
SamplerState color_sampler : register(s5, space0);

cbuffer cb0 : register(b22, space0) {
  float4 cb0_data[11];
};

cbuffer cb1 : register(b23, space0) {
  float4 cb1_data[5];
};

// PQ constants exactly as they appear in the shader.
static const float PQ_M1 = 0.1593017578125f;   // 2610/16384
static const float PQ_M2 = 78.84375f;          // 2523/4096 * 128
static const float PQ_C1 = 0.8359375f;         // 3424/4096
static const float PQ_C2 = 18.8515625f;        // 2413/4096 * 32
static const float PQ_C3 = 18.6875f;           // 2392/4096 * 32

float EncodePQChannel(float value) {
  // log/exp sequence in the original is pow(|x|, M1)
  float p = pow(abs(value), PQ_M1);
  float num = PQ_C1 + PQ_C2 * p;
  float den = 1.0f + PQ_C3 * p;
  return pow(num / den, PQ_M2);
}

float4 main(float4 position : SV_Position, float2 texcoord : TEXCOORD0) : SV_Target0 {
  // sample + mad
  float4 color = color_texture.Sample(color_sampler, texcoord);
  color = color * cb0_data[8] + cb0_data[7];

  // Optional tonemap-3D LUT lookup
  if (cb0_data[10].x != 0.0f) {
    color.xyz = tonemap_lut.SampleLevel(lut_sampler, color.xyz, 0).xyz;
  }

  // Optional BT.709 -> BT.2020 conversion followed by PQ encode
  if (cb0_data[9].y != 0.0f) {
    float3 bt2020;
    bt2020.x = dot(float3(0.6274039745330810546875f, 0.329281985759735107421875f, 0.043313600122928619384765625f), color.xyz);
    bt2020.y = dot(float3(0.06909699738025665283203125f, 0.919539988040924072265625f, 0.0113612003624439239501953125f), color.xyz);
    bt2020.z = dot(float3(0.01639159955084323883056640625f, 0.0880132019519805908203125f, 0.895595014095306396484375f), color.xyz);

    float3 scaled = bt2020 * cb1_data[0].x / cb1_data[3].w;
    color.xyz = float3(EncodePQChannel(scaled.x), EncodePQChannel(scaled.y), EncodePQChannel(scaled.z));
  }

  // Alpha premultiply toggle
  float3 premultiplied = color.xyz * color.w;
  color.xyz = (cb0_data[9].x == 0.0f) ? color.xyz : premultiplied;

  // Calibration: squared alpha when calibration value != 1
  float calibration_alpha = calibration[0].m0.w;
  float alpha_scaled = color.w * calibration_alpha;
  float alpha_squared = alpha_scaled * alpha_scaled;
  color.z = (calibration_alpha != 1.0f) ? alpha_squared : color.xyz.z;

  float calibration_x = calibration[0].m0.x;
  color.w = color.w * calibration_x;

  // Vignette
  if (cb0_data[10].y != 0.0f) {
    float v = color.w * cb0_data[9].z;
    color.w = (cb0_data[9].z != 0.0f) ? v : color.w;

    if (cb0_data[9].w != 0.0f) {
      float curved = -0.5f * (cos(color.w * 3.1415927410125732421875f) - 1.0f);
      color.w = curved;
    }
  }

  color.w = saturate(color.w);
  return color;
}
