/*
 * DX12 replacement for shader 0x20270B14 (ps_5_1) -- RDR2 tone-mapping pass.
 * This is the smallest of the nine tone-map variants collected in the DX12
 * capture; the other eight share this shader's tail (LUT atlas -> look presets
 * -> grading curve -> dither) and differ only in the upstream inputs.
 *
 * Structure is recovered from the game's own DX12 bytecode, disassembled with
 * the Microsoft shader disassembler into captures/msasm/0x20270B14.ps_5_1.asm.
 * Every texture register, cbuffer index, structured-buffer stride and arithmetic
 * operation below is taken from that disassembly.
 *
 * This pass is NOT a translation of the Vulkan mod's tonemap_*.frag.vk.glsl.
 * The Vulkan and DX12 passes differ: for instance Vulkan folds a
 * `mix(..., mix(..., ...))` around the third look-up table where DX12 blends it
 * with `lift(dst - src)`-style lerps, and DX12 evaluates both tone-map branches
 * and selects, whereas Vulkan branches. All operands here come from the DX12
 * bytecode; the Vulkan source is used only as the reference for what RenoDX
 * changes.
 *
 * ---------------------------------------------------------------- vanilla ----
 * With ToneMapper = Vanilla (RENODX_TONE_MAP_TYPE == 0), CUSTOM_LUT_ENCODING == 0,
 * CUSTOM_LUT_STRENGTH == 1 and CUSTOM_DITHERING == 1, every helper below reduces
 * to exactly the original arithmetic, so the vanilla path is preserved.
 *
 * ------------------------------------------------------- unverified in-game ----
 * This has only been validated by compilation and by comparing the resulting
 * bindings against the original bytecode. It has not been run in the game.
 *
 * Bindings (must match the original exactly):
 *   cbuffer cb16[88] @ b16   cbuffer cb20[5] @ b20
 *   SamplerState @ s0, s2, s8
 *   StructuredBuffer, stride 1904 @ t3      StructuredBuffer, stride  236 @ t118
 *   Buffer<float4> @ t116                   Texture2DArray @ t25
 *   Texture1D @ t89                         Texture2D @ t44, t78, t81, t90,
 *                                           t100..t101, t106..t107,
 *                                           t109..t111
 *   in: SV_Position.xy, TEXCOORD0.xyz, TEXCOORD1.x    out: SV_Target0
 */
#include "../shared.h"
#include "../tonemap/tonemap.hlsli"

// ---------------------------------------------------------------------------
// Structured buffers. The element types reproduce the declared strides of the
// original dcl_resource_structured instructions. Only a handful of scalars are
// ever read; the offsets matter because the bytecode reads by byte offset.
//
// These two are easy to confuse: the smaller-looking stride belongs to the
// dither table (bound at t3) and the larger one to the exposure parameters
// (bound at t2). Read the byte offsets, not the names.
// ---------------------------------------------------------------------------

// t2 / stride 2004 bytes (501 floats). Only byte 16 is read.
struct RDR2ExposureParams {
  float value[501];
};
StructuredBuffer<RDR2ExposureParams> exposure_params : register(t2, space0);

// t3 / stride 1904 bytes (476 floats). Only byte 1840 is read, as an int.
struct RDR2DitherParams {
  float4 v[119];
};
StructuredBuffer<RDR2DitherParams> dither_params : register(t3, space0);

// t118 / stride 236 bytes (59 floats). Ten scalars are read, all within the
// first 56 bytes: an enable flag followed by two five-float look descriptions.
//
// This is declared as individual floats rather than float4[14] + padding
// because fxc rounds a structured buffer's declared stride up to a 4-byte
// boundary but a float3 tail is itself padded to 16 bytes, which yields 240.
// Fifty-nine scalars pack to exactly 236 with no padding at all.
struct RDR2LookPreset {
  float value[59];
};
StructuredBuffer<RDR2LookPreset> look_preset : register(t118, space0);

// ---------------------------------------------------------------------------
// Resources. Names are structural (what the shader does with them); the
// semantic ones are inferred and are not asserted as game resource names.
//
// t0 and t1 are declared but never read. They are kept because fxc numbers the
// resources it keeps by declaration order, so omitting them would shift every
// later texture into the wrong register.
// ---------------------------------------------------------------------------
Texture2D<float4> unused_t0 : register(t0, space0);
Texture2D<float4> unused_t1 : register(t1, space0);
Buffer<float4> tonemap_coefficients : register(t116, space0);

Texture2DArray<float4> dither_noise_texture : register(t25, space0);
Texture1D<float4> vignette_gradient : register(t89, space0);

Texture2D<float4> exposure_scale_texture : register(t44, space0);
Texture2D<float4> depth_texture : register(t78, space0);
Texture2D<float4> bloom_texture : register(t81, space0);
Texture2D<float4> exposure_texture : register(t90, space0);
Texture2D<float4> lut_atlas_0 : register(t106, space0);
Texture2D<float4> lut_atlas_1 : register(t100, space0);
Texture2D<float4> lut_atlas_2 : register(t101, space0);
Texture2D<float4> look_attribution_texture : register(t107, space0);
Texture2D<float4> alpha_texture : register(t109, space0);
Texture2D<float4> coord_texture : register(t110, space0);
Texture2D<float4> aberration_texture : register(t111, space0);

SamplerState sampler_0 : register(s0, space0);
SamplerState sampler_2 : register(s2, space0);
SamplerState sampler_8 : register(s8, space0);

cbuffer cb16 : register(b16, space0) {
  float4 cb16[88];
};

cbuffer cb20 : register(b20, space0) {
  float4 cb20[5];
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// The two look stages are described by a four-tap ramp plus a constant offset.
// Bytecode: `depth < pivot ? saturate((depth - in) * rise)
//                         : 1 - saturate((depth - pivot) * fall)`, then
// `saturate(... + offset)`.
float RDR2LookBlendMask(float depth, float4 ramp, float offset) {
  const float rising = saturate((depth - ramp.x) * ramp.y);
  const float falling = 1.f - saturate((depth - ramp.z) * ramp.w);
  return saturate((depth < ramp.z ? rising : falling) + offset);
}

// One slice lookup in an RDR2 LUT atlas: 16 slices of 16x64 texels tiled
// horizontally, with the slice fraction taken from the blue channel. The
// original computes this inline before every one of the six atlas fetches; the
// two taps are the neighbouring slices, interpolated by the fractional slice
// coordinate.
#define RDR2_SAMPLE_LUT_ATLAS(atlas, input, out)                                            \
  {                                                                                         \
    const float3 rdr2_lut_input = (input);                                                  \
    const float rdr2_lut_slice = floor(rdr2_lut_input.z * 14.9998999f);                     \
    const float2 rdr2_lut_uv = float2(0.001953125f, 0.03125f)                               \
                               + float2((rdr2_lut_slice * 0.0625f)                          \
                                            + (rdr2_lut_input.x * 0.05859375f),             \
                                        rdr2_lut_input.y * 0.9375f);                        \
    const float3 rdr2_lut_a = (atlas).Sample(sampler_2, rdr2_lut_uv).xyz;                   \
    const float3 rdr2_lut_b =                                                               \
        (atlas).Sample(sampler_2, rdr2_lut_uv + float2(0.0625f, 0.f)).xyz;                  \
    (out) = lerp(rdr2_lut_a, rdr2_lut_b, (rdr2_lut_input.z * 15.f) - rdr2_lut_slice);       \
  }

float4 main(
    float4 position : SV_Position,
    float3 texcoord : TEXCOORD0,
    // Declared as float4 to pin this to input register 2 (the original reads
    // v2.x); a bare float would be packed into the spare .w of register 1.
    float4 exposure_input : TEXCOORD1) : SV_Target0 {
  float4 r0, r1, r2, r3, r4, r5, r6;

  // ---------------------------------------------------------------------
  // 1. Exposure and the optional alpha composite (asm instr. 0-22).
  // ---------------------------------------------------------------------
  r0.xy = coord_texture.Sample(sampler_0, texcoord.xy).xy;
  const float2 sample_coord = r0.xy;

  r1.xyz = exposure_texture.Sample(sampler_8, sample_coord).xyz;
  r0.z = exposure_params[0].value[4];  // byte 16
  r1.xyz = r1.xyz * r0.zzz;

  r2.xyz = tonemap_coefficients.Load(0).xyz;
  r3.xyzw = tonemap_coefficients.Load(1).xyzw;
  r0.z = exposure_scale_texture.Load(int3(0, 0, 0)).x;

  // Inverse-luma key used much later to blend the look-up table result back in.
  r4.xyz = r1.xyz * r0.zzz;
  r0.w = dot(r4.xyz, float3(0.300000012f, 0.589999974f, 0.109999999f));
  r0.w = 0.0399999991f + r0.w;
  r0.w = 0.0399999991f / r0.w;

  // r1.w carries "the alpha channel is explicit, stop applying scene effects".
  r1.w = 0.f;
  if (cb16[64].x != 0.f) {
    r4.xyzw = alpha_texture.Sample(sampler_8, texcoord.xy).xyzw;
    r1.w = ((9.99999975e-05f + r4.w) >= 1.f) ? 1.f : 0.f;
    r5.xyz = r1.xyz * (1.f - r4.w) + r4.xyz;
    r1.xyz = (r1.w != 0.f) ? r4.xyz : r5.xyz;
  }

  r1.xyz = r1.xyz * r0.zzz;
  r1.xyz = min((float3)GetTonemapClampMax(), r1.xyz);

  // ---------------------------------------------------------------------
  // 2. Exposure curve and the radial falloff (asm instr. 23-99).
  // ---------------------------------------------------------------------
  if (r1.w == 0.f) {
    if (cb16[73].x != 0.f) {
      r4.xyz = bloom_texture.Sample(sampler_2, sample_coord).xyz;
      r4.xyz = r4.xyz * r0.zzz;
      r0.z = dot(r4.xyz, float3(0.300000012f, 0.589999974f, 0.109999999f));
      r0.z = max(cb16[75].z, r0.z);
      r0.z = min(cb16[75].w, r0.z);
      r2.w = cb16[75].x + r0.z;
      r2.w = log2(r2.w);
      r2.w = cb16[73].y * r2.w;
      r2.w = r2.w * 0.693147182f + cb16[73].z;
      r2.w = -10.f + r2.w;
      r0.z = cb16[75].y * r0.z + r2.w;
      r0.z = cb16[68].w + r0.z;
      r0.z = max(cb16[69].x, r0.z);
      r0.z = min(cb16[69].y, r0.z);

      // The original negates sign() here rather than using it directly; the
      // Vulkan variant of this pass has the opposite sign, so keep the bytecode
      // form rather than "fixing" it to match Vulkan.
      r2.w = cb16[69].z * abs(r0.z);
      r4.x = (r0.z > 0.f ? -1.f : 0.f) + (r0.z < 0.f ? 1.f : 0.f);
      r0.z = r2.w * r4.x + r0.z;
      r0.z = max(cb16[69].x, r0.z);
      r0.z = min(cb16[69].y, r0.z);

      r2.w = saturate(cb16[73].x);
      r0.z = -exposure_input + r0.z;
      r0.z = r2.w * r0.z + exposure_input;
      r0.z = exp2(r0.z);
    } else {
      r0.z = texcoord.z;
    }

    r4.xy = -cb16[53].xy + texcoord.xy;
    r5.x = dot(cb16[55].xy, r4.xy);
    r5.y = dot(cb16[55].zw, r4.xy);
    r4.xy = cb16[53].zw * r5.xy;
    r2.w = dot(r4.xy, r4.xy);
    r2.w = -cb16[56].x + r2.w;
    r2.w = cb16[56].w * r2.w;
    r2.w = max(0.f, r2.w);

    const bool radial_inside = (r2.w < 1.f);
    r4.y = 1.f - exp2(-10.f * r2.w);
    r2.w = (r2.w - 1.f) > 0.f ? exp2(10.f * (r2.w - 2.f)) : 0.f;
    r2.w = 0.998049974f + r2.w;
    r2.w = radial_inside ? r4.y : r2.w;

    r4.xyz = cb16[54].xyz * r1.xyz;
    r4.xyz = r4.xyz * cb16[54].www + -r1.xyz;
    r4.xyz = r2.www * r4.xyz + r1.xyz;
    r1.xyz = (cb16[54].w != 0.f) ? r4.xyz : r1.xyz;
  } else {
    r0.z = texcoord.z;
  }

  // ---------------------------------------------------------------------
  // 3. Time-of-day colour curve (asm instr. 100-112).
  // ---------------------------------------------------------------------
  r2.w = saturate(cb16[60].y * texcoord.y);
  r2.w = saturate(cb16[57].w + r2.w);
  r4.x = saturate(-cb16[59].w + texcoord.y);
  r4.x = saturate(cb16[60].x * r4.x);
  r4.x = saturate(-cb16[58].w + r4.x);
  r4.yzw = cb16[59].xyz + -cb16[57].xyz;
  r4.yzw = r2.www * r4.yzw + cb16[57].xyz;
  r5.xyz = -cb16[59].xyz + cb16[58].xyz;
  r5.xyz = r4.xxx * r5.xyz + cb16[59].xyz;
  r5.xyz = r5.xyz + -r4.yzw;
  r4.xyz = texcoord.yyy * r5.xyz + r4.yzw;
  r1.xyz = r4.xyz * r1.xyz;

  // ---------------------------------------------------------------------
  // 4. Tone map (asm instr. 113-134). This is where RenoDX replaces the game's
  //    curve. The original evaluates both the HDR and the clamped SDR branch and
  //    selects on cb20[0].w; ApplyToneMap does the same internally.
  // ---------------------------------------------------------------------
  if (RENODX_TONE_MAP_TYPE != 0.f) {
    // _488 = tonemap_coefficients[0], _489 = tonemap_coefficients[1],
    // _638 = r0.z (exposure), _m6 = cb20[1].z (white precompute).
    r1.xyz = ApplyToneMap(
        r1.xyz,
        cb20[0].w != 0.f,
        r0.z,
        cb20[1].z,
        (uint)cb20[1].x,
        cb20[2].z,
        r2.xyz,
        r3.xyzw);
  } else {
    r2.w = (cb20[1].x != 0.f) ? cb20[2].z : r2.z;
    r4.x = r0.z / cb20[1].z;
    r4.xyz = r4.xxx * r1.xyz;
    r4.xyz = max((float3)0.f, r4.xyz);
    r5.xyz = r2.xxx * r4.xyz + r3.xxx;
    r5.xyz = r4.xyz * r5.xyz + r3.yyy;
    r6.xyz = r2.xxx * r4.xyz + r2.yyy;
    r4.xyz = r4.xyz * r6.xyz + r3.zzz;
    r4.xyz = r5.xyz / r4.xyz;
    r4.xyz = r4.xyz + -r3.www;
    r4.xyz = r4.xyz * r2.www;
    r4.xyz = cb20[1].zzz * r4.xyz;
    r1.xyz = r1.xyz * r0.zzz;
    r1.xyz = max((float3)0.f, r1.xyz);
    r5.xyz = r2.xxx * r1.xyz + r3.xxx;
    r5.xyz = r1.xyz * r5.xyz + r3.yyy;
    r2.xyw = r2.xxx * r1.xyz + r2.yyy;
    r1.xyz = r1.xyz * r2.xyw + r3.zzz;
    r1.xyz = r5.xyz / r1.xyz;
    r1.xyz = r1.xyz + -r3.www;
    r1.xyz = saturate(r1.xyz * r2.zzz);
    r1.xyz = (cb20[0].w != 0.f) ? r4.xyz : r1.xyz;
  }

  // ---------------------------------------------------------------------
  // 5. Vignette gradient, applied before the LUT (asm instr. 135-148).
  // ---------------------------------------------------------------------
  if (r1.w == 0.f) {
    if (cb16[50].w != 0.f) {
      r2.xy = -cb16[49].xy + texcoord.xy;
      r3.x = dot(cb16[51].xy, r2.xy);
      r3.y = dot(cb16[51].zw, r2.xy);
      r2.xy = cb16[49].zw * r3.xy;
      r0.z = dot(r2.xy, r2.xy);
      r0.z = -cb16[52].x + r0.z;
      r0.z = saturate(cb16[52].w * r0.z);
      r0.z = vignette_gradient.Sample(sampler_2, r0.z).w;
      r0.z = cb16[50].w * r0.z;
      r2.xyz = cb16[50].xyz + -r1.xyz;
      r1.xyz = r0.zzz * r2.xyz + r1.xyz;
    }
  }

  // ---------------------------------------------------------------------
  // 6. Encode the linear colour into the LUT's input domain
  //    (asm instr. 149-159).
  // ---------------------------------------------------------------------
  const bool skip_lut_encoding = (asuint(cb20[0].w) != 0u) && (asuint(cb20[0].z) == 0u);
  r1.xyz = EncodeLUTInput(
      r1.xyz,
      cb20[2].w,
      cb20[3].x,
      cb20[3].y,
      cb20[3].z,
      skip_lut_encoding);

  // ---------------------------------------------------------------------
  // 7. Lift into BT.2020 and build the look mask (asm instr. 160-173).
  //    BT2020FromBT709() emits exactly the three dot products in the bytecode.
  // ---------------------------------------------------------------------
  r2.xyz = BT2020FromBT709(r1.xyz);
  r2.xyz = max(float3(0.00999999978f, 0.f, 0.f), r2.xyz);
  r2.z = r2.y + r2.z;
  r2.x = r2.z / r2.x;
  r2.x = 1.f + r2.x;
  r2.x = r2.x * 1.33000004f + -1.67999995f;
  r2.x = r2.y * r2.x;
  r2.xyz = cb16[83].xyz * r2.xxx;
  r2.xyz = saturate(cb16[83].www * r2.xyz);
  r0.w = saturate(r0.w * cb16[84].x + cb16[84].y);
  r2.xyz = r2.xyz + -r1.xyz;
  r1.xyz = r0.www * r2.xyz + r1.xyz;

  // ---------------------------------------------------------------------
  // 8. Optional aberration sample (asm instr. 174-185).
  // ---------------------------------------------------------------------
  if (cb16[86].w != 0.f) {
    r2.xy = cb16[87].zy + -cb16[87].wx;
    r2.xy = texcoord.yx * r2.xy + cb16[87].wx;
    r2.zw = float2(-0.5f, -0.5f) + texcoord.xy;
    r2.zw = cb16[86].zz * r2.zw;
    r2.xy = r2.zw / r2.xy;
    r2.xy = -cb16[86].xy + r2.xy;
    r2.xy = float2(0.5f, 0.5f) + r2.xy;
    r2.xyz = aberration_texture.Sample(sampler_2, r2.xy).xyz;
    r2.xyz = r2.xyz + -r1.xyz;
    r1.xyz = cb16[86].www * r2.xyz + r1.xyz;
  }

  // ---------------------------------------------------------------------
  // 9. LUT input compression, atlas lookups, look presets, decode
  //    (asm instr. 186-264).
  // ---------------------------------------------------------------------
  if (r1.w == 0.f) {
    float compression_scale;
    const float3 lut_input_color = CompressLUTInput(
        r1.xyz,
        skip_lut_encoding,
        (uint)cb20[1].y,
        cb20[1].w,
        cb20[2].x,
        cb20[2].y,
        compression_scale);

    float3 lut_color;
    RDR2_SAMPLE_LUT_ATLAS(lut_atlas_0, lut_input_color, lut_color);

    // Byte 0 is the "look presets are active" flag. The four bytecode loads at
    // byte offsets 0, 16, 32 and 48 are contiguous once the register-limited
    // .xy/.zw pairs are merged, so read them as scalars.
    if ((int)look_preset[0].value[0] > 0) {
      // Depth-derived key that selects between the two look stages.
      const float depth_key =
          cb16[0].z / (1.f + cb16[0].w - depth_texture.SampleLevel(sampler_0, sample_coord, 0).x);

      // Look A: ramp is bytes 16..28, offset is byte 32.
      // Look B: ramp is bytes 36..48, offset is byte 52.
      const float4 look_a_ramp = float4(
          look_preset[0].value[4], look_preset[0].value[5],
          look_preset[0].value[6], look_preset[0].value[7]);
      const float look_a_offset = look_preset[0].value[8];

      const float4 look_b_ramp = float4(
          look_preset[0].value[9], look_preset[0].value[10],
          look_preset[0].value[11], look_preset[0].value[12]);
      const float look_b_offset = look_preset[0].value[13];

      float3 lut_color_2;
      RDR2_SAMPLE_LUT_ATLAS(lut_atlas_1, lut_color, lut_color_2);
      const float mask_a = RDR2LookBlendMask(depth_key, look_a_ramp, look_a_offset);
      lut_color_2 = lerp(lut_color, lut_color_2, mask_a);

      float3 lut_color_3;
      RDR2_SAMPLE_LUT_ATLAS(lut_atlas_2, lut_color_2, lut_color_3);
      const float mask_b = RDR2LookBlendMask(depth_key, look_b_ramp, look_b_offset);
      lut_color_3 = lerp(lut_color_2, lut_color_3, mask_b);

      const float attribution = dot(
          look_attribution_texture.Sample(sampler_2, sample_coord).xyz,
          float3(0.212599993f, 0.715200007f, 0.0722000003f));
      lut_color = lerp(lut_color_2, lut_color_3, attribution);
    }

    r1.xyz = DecodeLUTInput(lut_color, r1.xyz, compression_scale);
  }

  // ---------------------------------------------------------------------
  // 10. Luma, max-channel selection and the game's display curve
  //     (asm instr. 265-275).
  // ---------------------------------------------------------------------
  r0.w = dot(r1.xyz, float3(0.298999995f, 0.587000012f, 0.114f));
  r1.w = max(r1.y, r1.z);
  r1.w = max(r1.x, r1.w);
  r2.xyz = (cb16[41].w != 0.f) ? r1.xyz : r1.www;
  r2.xyz = -cb16[42].xyz + r2.xyz;
  r2.xyz = saturate(cb16[41].xyz * r2.xyz);
  r2.xyz = log2(r2.xyz);
  r2.xyz = cb16[42].www * r2.xyz;
  r2.xyz = exp2(r2.xyz);
  r3.xyz = cb16[40].xyz + -cb16[39].xyz;
  r2.xyz = r2.xyz * r3.xyz + cb16[39].xyz;

  // ---------------------------------------------------------------------
  // 11. Dither (asm instr. 276-292).
  // ---------------------------------------------------------------------
  const int2 dither_pixel = int2(position.xy) & 63;
  r1.w = dither_params[0].v[115].x;  // byte 1840
  r3.z = (int)r1.w & 31;
  r1.w = dither_noise_texture.Load(int4(dither_pixel, r3.z, 0)).x;
  const float dither_raw = r1.w * 2.f + -1.f;
  // sign() reconstruction: negate the positive test and add the negative test.
  r2.w = -((dither_raw > 0.f) ? 1.f : 0.f) + ((dither_raw < 0.f) ? 1.f : 0.f);
  r3.x = 1.f - abs(dither_raw);
  r3.x = sqrt(r3.x);
  r3.x = 1.f - r3.x;
  r2.w = r3.x * r2.w;
  r1.w = (cb20[0].w != 0.f) ? r2.w : dither_raw;

  r0.xyz = r1.www * r2.xyz * CUSTOM_DITHERING + r1.xyz;
  r1.xyzw = saturate(r0.xyzw);
  float4 output = (cb20[0].w != 0.f) ? r0.xyzw : r1.xyzw;

  // ---------------------------------------------------------------------
  // 12. RenoDX grading and display mapping.
  //     Mirrors the Vulkan mod, which applies this to the final colour of every
  //     tone-map pass. It is a no-op while IS_TONEMAPPED is set, which is the
  //     state this shader itself establishes through OnTonemapShaderDrawn.
  // ---------------------------------------------------------------------
  output.xyz = ApplyGradingAndDisplayMap(output.xyz, texcoord.xy);
  return output;
}
