#ifndef SRC_GAMES_RDR2DX12_PERCEPTUAL_COLOR_HLSLI_
#define SRC_GAMES_RDR2DX12_PERCEPTUAL_COLOR_HLSLI_

// RDR2VK perceptual color transforms, grading, Yf, and PsychoV gamut mapping.
// Names are prefixed to replace HLSL namespaces.
//
// HLSL (DX12) port of reference/rdr2vk/perceptual_color.glsl.
//
// Matrix representation: GLSL mat3 constructors accept COLUMN vectors, while
// HLSL float3x3 literals are built from ROW vectors. Every GLSL constructor
// column below is copied verbatim as a float3x3 literal ROW, so each matrix in
// this file is the TRANSPOSE of its GLSL counterpart. Consequently every GLSL
// `M * v` product is written as `mul(v, M)`, and nested products reverse
// order: GLSL `A * (B * v)` -> HLSL `mul(mul(v, B), A)`. Matrix-valued
// function parameters use the same transposed representation.
//
// This file is self-contained: no external includes; all dependencies are
// defined below.

static const float3x3 renodx_color_macleod_boynton_XYZ_TO_LMS_2006 = float3x3(
    float3(0.185082982238733, -0.134433056469973, 0.000789456671966863),
    float3(0.584081279463687, 0.405752392775348, -0.000912281325916184),
    float3(-0.0240722415044404, 0.0358252602217631, 0.0198490812339463));

static const float3x3 renodx_color_macleod_boynton_LMS_TO_XYZ_2006 = float3x3(
    float3(2.628474773947687, 0.8765342837340055, -0.06425592569153735),
    float3(-3.761263499279893, 1.2003038085515867, 0.20476359921126536),
    float3(9.9763571339745, -1.1033785928646218, 49.93266413348867));

static const float3x3 renodx_color_macleod_boynton_BT709_TO_XYZ_MAT = float3x3(
    float3(0.4123907993, 0.2126390059, 0.0193308187),
    float3(0.3575843394, 0.7151686788, 0.1191947798),
    float3(0.1804807884, 0.0721923154, 0.9505321522));

static const float3x3 renodx_color_macleod_boynton_XYZ_TO_BT709_MAT = float3x3(
    float3(3.2409699419, -0.9692436363, 0.0556300797),
    float3(-1.5373831776, 1.8759675015, -0.2039769589),
    float3(-0.4986107603, 0.0415550574, 1.0569715142));

static const float3x3 renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT = float3x3(
    float3(0.6369580483, 0.2627002120, 0.0000000000),
    float3(0.1446169036, 0.6779980715, 0.0280726930),
    float3(0.1688809752, 0.0593017165, 1.0609850577));

static const float3x3 renodx_color_macleod_boynton_XYZ_TO_BT2020_MAT = float3x3(
    float3(1.7166511880, -0.6666843518, 0.0176398574),
    float3(-0.3556707838, 1.6164812366, -0.0427706133),
    float3(-0.2533662814, 0.0157685458, 0.9421031212));

static const float3x3 renodx_color_XYZ_TO_STOCKMAN_SHARP_LMS_MAT = float3x3(
    float3(0.2670502842655792, -0.38706882411220156, 0.026727793989083093),
    float3(0.8471990148492798, 1.165429935890458, -0.02729131667566509),
    float3(-0.03470416612462053, 0.10302286696614202, 0.5333267257603284));

static const float3x3 renodx_color_STOCKMAN_SHARP_LMS_TO_XFYFZF_MAT = float3x3(
    float3(1.94735469, 0.68990272, 0.0),
    float3(-1.41445123, 0.34832189, 0.0),
    float3(0.36476327, 0.0, 1.93485343));

static const float2 renodx_color_macleod_boynton_WHITE_POINT_D65 = float2(0.31272, 0.32903);

static const float renodx_color_macleod_boynton_EPSILON = 1e-20;
static const float renodx_color_macleod_boynton_INTERVAL_MAX = 1e30;
static const float renodx_color_macleod_boynton_MB_NEAR_WHITE_EPSILON = 1e-14;

float renodx_color_macleod_boynton_DivideSafe(float a, float b, float fallback) {
  return (b == 0.0) ? fallback : (a / b);
}

float3 renodx_color_macleod_boynton_xyz_from_xyY(float3 xyY) {
  float x = xyY.x;
  float y = xyY.y;
  float Y = xyY.z;
  float safe_y = max(y, 1e-10);

  float X = x * Y / safe_y;
  float Z = (1.0 - x - y) * Y / safe_y;
  return float3(X, Y, Z);
}

float2 renodx_color_macleod_boynton_MB_From_LMS(float3 lms) {
  float t = lms.x + lms.y;
  if (t <= 0.0) {
    return (float2)(0.0);
  }

  return float2(
      renodx_color_macleod_boynton_DivideSafe(lms.x, t, 0.0),
      renodx_color_macleod_boynton_DivideSafe(lms.z, t, 0.0));
}

float3 renodx_color_macleod_boynton_LMS_From_MB_T(float2 mb, float t) {
  float r = mb.x;
  float b = mb.y;
  return float3(r * t, (1.0 - r) * t, b * t);
}

float2 renodx_color_macleod_boynton_MB_White_D65() {
  float3 d65_xyz = renodx_color_macleod_boynton_xyz_from_xyY(
      float3(renodx_color_macleod_boynton_WHITE_POINT_D65, 1.0));
  float3 d65_lms = mul(d65_xyz, renodx_color_macleod_boynton_XYZ_TO_LMS_2006);
  return renodx_color_macleod_boynton_MB_From_LMS(d65_lms);
}

float3 renodx_color_macleod_boynton_TransferPurityBT2020(
    float3 rgb_target_bt2020_linear, float3 rgb_source_bt2020_linear, float strength) {
  if (strength <= 0.0) {
    return max(rgb_target_bt2020_linear, (float3)(0.0));
  }

  const float t_min = 1e-7;
  float2 white = renodx_color_macleod_boynton_MB_White_D65();

  float3 xyz_target = mul(rgb_target_bt2020_linear, renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT);
  float3 lms_target = mul(xyz_target, renodx_color_macleod_boynton_XYZ_TO_LMS_2006);
  float target_t = lms_target.x + lms_target.y;
  if (target_t <= t_min) {
    return max(rgb_target_bt2020_linear, (float3)(0.0));
  }

  float3 xyz_source = mul(rgb_source_bt2020_linear, renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT);
  float3 lms_source = mul(xyz_source, renodx_color_macleod_boynton_XYZ_TO_LMS_2006);
  float source_t = lms_source.x + lms_source.y;
  if (source_t <= t_min) {
    return max(rgb_target_bt2020_linear, (float3)(0.0));
  }

  float2 mb_target = renodx_color_macleod_boynton_MB_From_LMS(lms_target);
  float2 mb_source = renodx_color_macleod_boynton_MB_From_LMS(lms_source);

  float2 target_offset = mb_target - white;
  float target_len = length(target_offset);
  if (target_len < renodx_color_macleod_boynton_MB_NEAR_WHITE_EPSILON) {
    return max(rgb_target_bt2020_linear, (float3)(0.0));
  }

  float source_len = length(mb_source - white);
  float out_len = (strength >= 1.0)
                      ? source_len
                      : lerp(target_len, source_len, clamp(strength, 0.0, 1.0));

  float2 target_dir = target_offset / target_len;
  float2 mb_out = white + target_dir * out_len;
  float3 lms_out = renodx_color_macleod_boynton_LMS_From_MB_T(mb_out, target_t);
  float3 xyz_out = mul(lms_out, renodx_color_macleod_boynton_LMS_TO_XYZ_2006);
  float3 rgb_out = mul(xyz_out, renodx_color_macleod_boynton_XYZ_TO_BT2020_MAT);
  return max(rgb_out, (float3)(0.0));
}

void renodx_color_macleod_boynton_IntervalLower0(float a, float b, out float lo, out float hi) {
  if (abs(a) < renodx_color_macleod_boynton_EPSILON) {
    if (b >= 0.0) {
      lo = -renodx_color_macleod_boynton_INTERVAL_MAX;
      hi = renodx_color_macleod_boynton_INTERVAL_MAX;
    } else {
      lo = 1.0;
      hi = 0.0;
    }
    return;
  }

  float t0 = renodx_color_macleod_boynton_DivideSafe(-b, a, 0.0);
  if (a > 0.0) {
    lo = t0;
    hi = renodx_color_macleod_boynton_INTERVAL_MAX;
  } else {
    lo = -renodx_color_macleod_boynton_INTERVAL_MAX;
    hi = t0;
  }
}

struct renodx_color_macleod_boynton_MBPurityDebug {
  float3 rgbOut;
  float purityCur01;
};

// NOTE: rgb_to_xyz_mat / xyz_to_rgb_mat are passed in the transposed
// representation described in the file header (GLSL columns stored as HLSL
// rows), so products are written mul(v, M).
renodx_color_macleod_boynton_MBPurityDebug renodx_color_macleod_boynton_ApplyInternal(
    float3 rgb_linear, float purity_value, float curve_gamma,
    float2 mb_white_override, float t_min,
    float3x3 rgb_to_xyz_mat, float3x3 xyz_to_rgb_mat) {
  renodx_color_macleod_boynton_MBPurityDebug result;
  result.rgbOut = rgb_linear;
  result.purityCur01 = 0.0;

  float3 xyz = mul(rgb_linear, rgb_to_xyz_mat);
  float3 lms = mul(xyz, renodx_color_macleod_boynton_XYZ_TO_LMS_2006);

  float t = lms.x + lms.y;
  if (t <= t_min) {
    return result;
  }

  float2 white = (mb_white_override.x >= 0.0 && mb_white_override.y >= 0.0)
                     ? mb_white_override
                     : renodx_color_macleod_boynton_MB_White_D65();

  float2 mb0 = renodx_color_macleod_boynton_MB_From_LMS(lms);
  float2 direction = mb0 - white;
  if (dot(direction, direction) < renodx_color_macleod_boynton_MB_NEAR_WHITE_EPSILON) {
    return result;
  }

  float3 lms_t0 = renodx_color_macleod_boynton_LMS_From_MB_T(white, t);
  float3 xyz_t0 = mul(lms_t0, renodx_color_macleod_boynton_LMS_TO_XYZ_2006);
  float3 rgb_t0 = mul(xyz_t0, xyz_to_rgb_mat);

  float3 a = rgb_linear - rgb_t0;

  float t_lo = 0.0;
  float t_hi = renodx_color_macleod_boynton_INTERVAL_MAX;
  float lo;
  float hi;

  renodx_color_macleod_boynton_IntervalLower0(a.x, rgb_t0.x, lo, hi);
  t_lo = max(t_lo, lo);
  t_hi = min(t_hi, hi);
  renodx_color_macleod_boynton_IntervalLower0(a.y, rgb_t0.y, lo, hi);
  t_lo = max(t_lo, lo);
  t_hi = min(t_hi, hi);
  renodx_color_macleod_boynton_IntervalLower0(a.z, rgb_t0.z, lo, hi);
  t_lo = max(t_lo, lo);
  t_hi = min(t_hi, hi);

  if (t_hi < t_lo) {
    result.rgbOut = max(rgb_linear, (float3)(0.0));
    return result;
  }

  float t_max = max(0.0, t_hi);
  float p_cur = (t_max > renodx_color_macleod_boynton_EPSILON)
                    ? renodx_color_macleod_boynton_DivideSafe(1.0, t_max, 0.0)
                    : 0.0;
  result.purityCur01 = clamp(p_cur, 0.0, 1.0);

  float purity = pow(clamp(purity_value, 0.0, 1.0), max(curve_gamma, 1e-6));
  float t_final = purity * t_max;

  float2 mb_final = white + t_final * direction;
  float3 lms_final = renodx_color_macleod_boynton_LMS_From_MB_T(mb_final, t);
  float3 xyz_final = mul(lms_final, renodx_color_macleod_boynton_LMS_TO_XYZ_2006);
  float3 rgb_final = mul(xyz_final, xyz_to_rgb_mat);
  result.rgbOut = max(rgb_final, (float3)(0.0));
  return result;
}

renodx_color_macleod_boynton_MBPurityDebug renodx_color_macleod_boynton_ApplyBT2020(
    float3 rgb2020_linear, float purity01, float curve_gamma, float2 mb_white_override,
    float t_min) {
  return renodx_color_macleod_boynton_ApplyInternal(
      rgb2020_linear, purity01, curve_gamma, mb_white_override, t_min,
      renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT,
      renodx_color_macleod_boynton_XYZ_TO_BT2020_MAT);
}

float renodx_color_yf_from_LMS(float3 lms) {
  return mul(lms, renodx_color_STOCKMAN_SHARP_LMS_TO_XFYFZF_MAT).y;
}

float renodx_color_yf_from_BT709(float3 bt709_linear) {
  float3 xyz = mul(bt709_linear, renodx_color_macleod_boynton_BT709_TO_XYZ_MAT);
  return renodx_color_yf_from_LMS(mul(xyz, renodx_color_XYZ_TO_STOCKMAN_SHARP_LMS_MAT));
}

float renodx_color_yf_from_BT2020(float3 bt2020_linear) {
  float3 xyz = mul(bt2020_linear, renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT);
  return renodx_color_yf_from_LMS(mul(xyz, renodx_color_XYZ_TO_STOCKMAN_SHARP_LMS_MAT));
}

struct UserGradingConfig {
  float exposure;
  float highlights;
  float contrast_highlights;
  float shadows;
  float contrast_shadows;
  float contrast;
  float flare;
  float gamma;
  float saturation;
  float dechroma;
  float highlight_saturation;
  float hue_emulation;
  float purity_emulation;
};

float renodx_usergrading_DivideSafe(float a, float b, float fallback) {
  return (b == 0.0) ? fallback : (a / b);
}

float renodx_usergrading_SafeDivision(float quotient, float divisor, float fallback) {
  return renodx_usergrading_DivideSafe(quotient, divisor, fallback);
}

float renodx_usergrading_saturate(float x) {
  return clamp(x, 0.0, 1.0);
}

float3 renodx_usergrading_Luminance(float3 color, float incorrect_y, float correct_y, float strength) {
  float ratio = renodx_usergrading_DivideSafe(correct_y, incorrect_y, 1.0);
  return color * lerp(1.0, ratio, strength);
}

float Highlights(float x, float highlights, float mid_gray) {
  if (highlights == 1.0) return x;

  if (highlights > 1.0) {
    float t = 0.0;
    if (x > mid_gray) {
      t = renodx_usergrading_saturate(log2(x / mid_gray) / log2(1.0 / mid_gray));
    }
    t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    return lerp(x, mid_gray * pow(x / mid_gray, highlights), t);
  } else {
    float b = mid_gray * pow(x / mid_gray, 2.0 - highlights);
    float t = 0.0;
    if (x > mid_gray) {
      t = renodx_usergrading_saturate(log2(x / mid_gray) / log2(1.0 / mid_gray));
    }
    t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    return renodx_usergrading_DivideSafe(x * x, lerp(x, b, t), x);
  }
}

float Shadows(float x, float shadows, float mid_gray) {
  if (shadows == 1.0) return x;

  float ratio = max(renodx_usergrading_DivideSafe(x, mid_gray, 0.0), 0.0);
  float base_term = x * mid_gray;
  float base_scale = renodx_usergrading_DivideSafe(base_term, ratio, 0.0);

  if (shadows > 1.0) {
    float raised = x * (1.0 + renodx_usergrading_DivideSafe(base_term, pow(ratio, shadows), 0.0));
    float reference = x * (1.0 + base_scale);
    float shadow_floor = mid_gray / 16.0;
    float t = 1.0;
    if (x > shadow_floor) {
      t = renodx_usergrading_saturate(log2(x / mid_gray) / log2(shadow_floor / mid_gray));
    }
    t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    return x + (raised - reference) * t;
  } else {
    float lowered = x * (1.0 - renodx_usergrading_DivideSafe(base_term, pow(ratio, 2.0 - shadows), 0.0));
    float reference = x * (1.0 - base_scale);
    float shadow_floor = mid_gray / 16.0;
    float t = 1.0;
    if (x > shadow_floor) {
      t = renodx_usergrading_saturate(log2(x / mid_gray) / log2(shadow_floor / mid_gray));
    }
    t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    return x + (lowered - reference) * t;
  }
}

float ContrastAndFlare(
    float x, float contrast, float contrast_highlights, float contrast_shadows,
    float flare, float mid_gray) {
  if (contrast == 1.0 && flare == 0.0 && contrast_highlights == 1.0 && contrast_shadows == 1.0) {
    return x;
  }

  float x_normalized = x / mid_gray;
  float split_contrast = (x < mid_gray) ? contrast_shadows : contrast_highlights;
  float flare_ratio = renodx_usergrading_DivideSafe(x_normalized + flare, x_normalized, 1.0);
  float exponent = contrast * split_contrast * flare_ratio;
  return pow(x_normalized, exponent) * mid_gray;
}

float3 ApplyLuminanceGrading(float3 untonemapped, float lum, UserGradingConfig config, float mid_gray) {
  if (config.exposure == 1.0 && config.shadows == 1.0 && config.highlights == 1.0 && config.contrast == 1.0
      && config.contrast_highlights == 1.0 && config.contrast_shadows == 1.0 && config.flare == 0.0 && config.gamma == 1.0) {
    return untonemapped;
  }

  float3 color = untonemapped;
  color *= config.exposure;

  float lum_gamma_adjusted = (lum < 1.0) ? pow(lum, config.gamma) : lum;

  float lum_contrasted = ContrastAndFlare(
      lum_gamma_adjusted,
      config.contrast,
      config.contrast_highlights,
      config.contrast_shadows,
      config.flare,
      mid_gray);

  float lum_highlighted = Highlights(lum_contrasted, config.highlights, mid_gray);
  float lum_shadowed = Shadows(lum_highlighted, config.shadows, mid_gray);
  float lum_final = lum_shadowed;

  color = renodx_usergrading_Luminance(color, lum, lum_final, 1.0);
  return color;
}

float3 ApplyHueAndPurityGrading(
    float3 ungraded_bt2020,
    float3 reference_bt2020,
    float lum,
    UserGradingConfig config) {
  float3 color_bt2020 = ungraded_bt2020;
  if (config.saturation == 1.0 && config.dechroma == 0.0 && config.hue_emulation == 0.0 && config.purity_emulation == 0.0 && config.highlight_saturation == 0.0) {
    return color_bt2020;
  }

  float curve_gamma = 1.0;
  float2 mb_white_override = (float2)(-1.0);
  float t_min = 1e-7;

  float kNearWhiteEpsilon = renodx_color_macleod_boynton_MB_NEAR_WHITE_EPSILON;
  float2 white = (mb_white_override.x >= 0.0 && mb_white_override.y >= 0.0)
                     ? mb_white_override
                     : renodx_color_macleod_boynton_MB_White_D65();

  float color_purity01 = renodx_color_macleod_boynton_ApplyBT2020(
                             color_bt2020, 1.0, 1.0, mb_white_override, t_min)
                             .purityCur01;

  if (config.hue_emulation != 0.0 || config.purity_emulation != 0.0) {
    float reference_purity01 = renodx_color_macleod_boynton_ApplyBT2020(
                                   reference_bt2020, 1.0, 1.0, mb_white_override, t_min)
                                   .purityCur01;

    float purity_current = color_purity01;
    float purity_ratio = 1.0;
    float3 hue_seed_bt2020 = color_bt2020;

    if (config.hue_emulation != 0.0) {
      float3 target_lms =
          mul(mul(color_bt2020, renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT), renodx_color_macleod_boynton_XYZ_TO_LMS_2006);
      float3 reference_lms =
          mul(mul(reference_bt2020, renodx_color_macleod_boynton_BT2020_TO_XYZ_MAT), renodx_color_macleod_boynton_XYZ_TO_LMS_2006);

      float target_t = target_lms.x + target_lms.y;
      if (target_t > t_min) {
        float2 target_direction = renodx_color_macleod_boynton_MB_From_LMS(target_lms) - white;
        float2 reference_direction = renodx_color_macleod_boynton_MB_From_LMS(reference_lms) - white;

        float target_len_sq = dot(target_direction, target_direction);
        float reference_len_sq = dot(reference_direction, reference_direction);

        if (target_len_sq > kNearWhiteEpsilon || reference_len_sq > kNearWhiteEpsilon) {
          float2 target_unit = (target_len_sq > kNearWhiteEpsilon)
                                   ? target_direction * rsqrt(target_len_sq)
                                   : (float2)(0.0);
          float2 reference_unit = (reference_len_sq > kNearWhiteEpsilon)
                                      ? reference_direction * rsqrt(reference_len_sq)
                                      : target_unit;

          if (target_len_sq <= kNearWhiteEpsilon) {
            target_unit = reference_unit;
          }

          float2 blended_unit = lerp(target_unit, reference_unit, config.hue_emulation);
          float blended_len_sq = dot(blended_unit, blended_unit);
          if (blended_len_sq <= kNearWhiteEpsilon) {
            blended_unit = (config.hue_emulation >= 0.5) ? reference_unit : target_unit;
            blended_len_sq = dot(blended_unit, blended_unit);
          }
          blended_unit *= rsqrt(max(blended_len_sq, 1e-20));

          float seed_len = sqrt(max(target_len_sq, 0.0));
          if (seed_len <= 1e-6) {
            seed_len = sqrt(max(reference_len_sq, 0.0));
          }
          seed_len = max(seed_len, 1e-6);

          hue_seed_bt2020 =
              mul(mul(renodx_color_macleod_boynton_LMS_From_MB_T(white + blended_unit * seed_len, target_t), renodx_color_macleod_boynton_LMS_TO_XYZ_2006), renodx_color_macleod_boynton_XYZ_TO_BT2020_MAT);

          float purity_post = renodx_color_macleod_boynton_ApplyBT2020(
                                  hue_seed_bt2020, 1.0, 1.0, mb_white_override, t_min)
                                  .purityCur01;
          purity_ratio = renodx_usergrading_SafeDivision(purity_current, purity_post, 1.0);
          purity_current = purity_post;
        }
      }
    }

    if (config.purity_emulation != 0.0) {
      float target_purity_ratio = renodx_usergrading_SafeDivision(reference_purity01, purity_current, 1.0);
      purity_ratio = lerp(purity_ratio, target_purity_ratio, config.purity_emulation);
    }

    float applied_purity01 = renodx_usergrading_saturate(purity_current * max(purity_ratio, 0.0));
    color_bt2020 = renodx_color_macleod_boynton_ApplyBT2020(
                       hue_seed_bt2020, applied_purity01, curve_gamma, mb_white_override, t_min)
                       .rgbOut;
    color_purity01 = applied_purity01;
  }

  float purity_scale = 1.0;

  if (config.dechroma != 0.0) {
    purity_scale *= lerp(1.0, 0.0, renodx_usergrading_saturate(pow(lum / (10000.0 / 100.0), (1.0 - config.dechroma))));
  }

  if (config.highlight_saturation != 0.0) {
    float percent_max = renodx_usergrading_saturate(lum * 100.0 / 10000.0);
    float blowout_strength = 100.0;
    float blowout_change = pow(1.0 - percent_max, blowout_strength * abs(config.highlight_saturation));
    if (config.highlight_saturation < 0.0) {
      blowout_change = 2.0 - blowout_change;
    }

    purity_scale *= blowout_change;
  }

  purity_scale *= config.saturation;

  if (purity_scale != 1.0) {
    float scaled_purity01 = renodx_usergrading_saturate(color_purity01 * max(purity_scale, 0.0));
    color_bt2020 = renodx_color_macleod_boynton_ApplyBT2020(
                       color_bt2020, scaled_purity01, curve_gamma, mb_white_override, t_min)
                       .rgbOut;
  }

  return color_bt2020;
}

// GLSL port of the BT.709-bound device-hull compression used by PsychoV test22.
static const float3 renodx_tonemap_psycho22_LMS_WEIGHTS = float3(
    0.68990272,
    0.34832189,
    0.0371597069161);

static const float3x3 renodx_tonemap_psycho22_STOCKMAN_LMS_TO_XYZ_MAT = float3x3(
    float3(1.8114629636873623, 0.6069124057314326, -0.0597250591701978),
    float3(-1.3081492612535468, 0.4159062592830001, 0.08684090099781155),
    float3(0.37056946406094754, -0.04084825533137022, 1.8543617734965625));

static const float renodx_tonemap_psycho22_GAMUT_EPSILON = 1e-20;
static const float renodx_tonemap_psycho22_MB_NEAR_WHITE_EPSILON = 1e-14;
static const float renodx_tonemap_psycho22_CIE1702_RAY_T_MAX = 1e20;
static const int renodx_tonemap_psycho22_CIE1702_EDGE_COUNT = 7;

static const float2 renodx_tonemap_psycho22_CIE1702_HALFSPACE_NORMALS[renodx_tonemap_psycho22_CIE1702_EDGE_COUNT] = {
    float2(-0.043889, -0.006807),
    float2(-0.007821, -0.008564),
    float2(-0.000604, -0.007942),
    float2(0.0, -0.080835),
    float2(0.953597, 0.307020),
    float2(-0.060969, 0.019752),
    float2(-0.106895, 0.004035)};

static const float renodx_tonemap_psycho22_CIE1702_HALFSPACE_NUMERATORS[renodx_tonemap_psycho22_CIE1702_EDGE_COUNT] = {
    0.0065035249,
    0.00104900495,
    0.000207697044,
    0.00165556648,
    0.252472349,
    0.0241967351,
    0.0199621232};

float3 renodx_tonemap_psycho22_StockmanLMSFromBT709(float3 bt709) {
  return mul(mul(bt709, renodx_color_macleod_boynton_BT709_TO_XYZ_MAT),
             renodx_color_XYZ_TO_STOCKMAN_SHARP_LMS_MAT);
}

float3 renodx_tonemap_psycho22_BT709FromStockmanLMS(float3 lms) {
  return mul(mul(lms, renodx_tonemap_psycho22_STOCKMAN_LMS_TO_XYZ_MAT),
             renodx_color_macleod_boynton_XYZ_TO_BT709_MAT);
}

float3 renodx_tonemap_psycho22_WeighLMS(float3 lms) {
  return lms * renodx_tonemap_psycho22_LMS_WEIGHTS;
}

float3 renodx_tonemap_psycho22_UnweighLMS(float3 weighted_lms) {
  return weighted_lms / renodx_tonemap_psycho22_LMS_WEIGHTS;
}

float3 renodx_tonemap_psycho22_DivideSafe(float3 numerator, float3 denominator, float3 fallback) {
  return float3(
      renodx_color_macleod_boynton_DivideSafe(numerator.x, denominator.x, fallback.x),
      renodx_color_macleod_boynton_DivideSafe(numerator.y, denominator.y, fallback.y),
      renodx_color_macleod_boynton_DivideSafe(numerator.z, denominator.z, fallback.z));
}

float3 renodx_tonemap_psycho22_MBFromWeightedLMS(float3 weighted_lms) {
  float y_mb = max(weighted_lms.x + weighted_lms.y, 0.0);
  float inverse_y = renodx_color_macleod_boynton_DivideSafe(1.0, y_mb, 0.0);
  return float3(weighted_lms.x * inverse_y, weighted_lms.z * inverse_y, y_mb);
}

float3 renodx_tonemap_psycho22_WeightedLMSFromMB(float2 mb, float y_mb) {
  return float3(mb.x, 1.0 - mb.x, mb.y) * y_mb;
}

float2 renodx_tonemap_psycho22_CIE1702WhiteChromaticity() {
  float3 d65_xyz = renodx_color_macleod_boynton_xyz_from_xyY(
      float3(renodx_color_macleod_boynton_WHITE_POINT_D65, 1.0));
  return renodx_tonemap_psycho22_MBFromWeightedLMS(
             renodx_tonemap_psycho22_WeighLMS(
                 mul(d65_xyz, renodx_color_XYZ_TO_STOCKMAN_SHARP_LMS_MAT)))
      .xy;
}

float renodx_tonemap_psycho22_RayExitTCIE1702(float2 origin, float2 direction) {
  if (dot(direction, direction) <= renodx_tonemap_psycho22_MB_NEAR_WHITE_EPSILON) {
    return renodx_tonemap_psycho22_CIE1702_RAY_T_MAX;
  }

  float2 white_to_origin = renodx_tonemap_psycho22_CIE1702WhiteChromaticity() - origin;
  float t_best = renodx_tonemap_psycho22_CIE1702_RAY_T_MAX;
  bool hit_any = false;

  for (int i = 0; i < renodx_tonemap_psycho22_CIE1702_EDGE_COUNT; ++i) {
    float2 halfspace_normal = renodx_tonemap_psycho22_CIE1702_HALFSPACE_NORMALS[i];
    float denominator = dot(halfspace_normal, direction);
    float numerator = renodx_tonemap_psycho22_CIE1702_HALFSPACE_NUMERATORS[i]
                      + dot(halfspace_normal, white_to_origin);
    float t = denominator > 1e-8
                  ? numerator / denominator
                  : renodx_tonemap_psycho22_CIE1702_RAY_T_MAX;
    t_best = min(t_best, t);
    hit_any = hit_any || (denominator > 1e-8);
  }

  return hit_any ? max(t_best, 0.0) : renodx_tonemap_psycho22_CIE1702_RAY_T_MAX;
}

float renodx_tonemap_psycho22_Cross2(float2 a, float2 b) {
  return a.x * b.y - a.y * b.x;
}

bool renodx_tonemap_psycho22_RaySegmentHit2D(
    float2 origin, float2 direction, float2 a, float2 b, out float t_hit) {
  t_hit = 0.0;
  float2 edge = b - a;
  float denominator = renodx_tonemap_psycho22_Cross2(direction, edge);
  if (abs(denominator) <= renodx_tonemap_psycho22_GAMUT_EPSILON) return false;

  float2 a_origin = a - origin;
  float t = renodx_tonemap_psycho22_Cross2(a_origin, edge) / denominator;
  float u = renodx_tonemap_psycho22_Cross2(a_origin, direction) / denominator;
  if (t < 0.0 || u < 0.0 || u > 1.0) return false;

  t_hit = t;
  return true;
}

float renodx_tonemap_psycho22_RayMaxTRGBTriangleInMB(
    float2 origin, float2 direction, float2 r, float2 g, float2 b, out bool has_solution) {
  has_solution = false;
  if (dot(direction, direction) <= renodx_tonemap_psycho22_MB_NEAR_WHITE_EPSILON) return 0.0;

  float t_best = 3.402823466e38;
  float t_hit;
  bool hit_any = false;

  if (renodx_tonemap_psycho22_RaySegmentHit2D(origin, direction, r, g, t_hit)) {
    t_best = min(t_best, t_hit);
    hit_any = true;
  }
  if (renodx_tonemap_psycho22_RaySegmentHit2D(origin, direction, g, b, t_hit)) {
    t_best = min(t_best, t_hit);
    hit_any = true;
  }
  if (renodx_tonemap_psycho22_RaySegmentHit2D(origin, direction, b, r, t_hit)) {
    t_best = min(t_best, t_hit);
    hit_any = true;
  }

  has_solution = hit_any;
  return hit_any ? max(t_best, 0.0) : 0.0;
}

float renodx_tonemap_psycho22_NeutwoPeakClip(float x, float peak, float clip) {
  float peak_safe = max(peak, 0.0);
  float clip_safe = max(clip, peak_safe);
  float x_squared = x * x;
  float clip_squared = clip_safe * clip_safe;
  float peak_squared = peak_safe * peak_safe;
  // NOTE: HLSL mad() is not guaranteed to be an IEEE-fused multiply-add
  // equivalent of GLSL fma(); results may differ from the reference in the
  // final ulp.
  float denominator_squared = mad(
      x_squared, clip_squared - peak_squared, clip_squared * peak_squared);
  return (clip_safe * peak_safe * x)
         * rsqrt(max(denominator_squared, renodx_tonemap_psycho22_GAMUT_EPSILON));
}

float renodx_tonemap_psycho22_NeutwoScaleFromRayT(float t_peak, float t_clip) {
  float t_peak_safe = max(t_peak, 0.0);
  float t_clip_safe = max(t_clip, t_peak_safe);
  return clamp(
      renodx_tonemap_psycho22_NeutwoPeakClip(1.0, t_peak_safe, t_clip_safe),
      0.0,
      1.0);
}

float renodx_tonemap_psycho22_SoftCompressionActivationFromRayT(float t_peak) {
  float outside = 1.0 - clamp(t_peak, 0.0, 1.0);
  return renodx_color_macleod_boynton_DivideSafe(outside, outside + 0.08, 0.0);
}

float3 renodx_tonemap_psycho22_ClampWeightedLMSToCIE1702(float3 weighted_lms) {
  float3 weighted_lms_clamped = max(weighted_lms, (float3)(0.0));
  float3 mb = renodx_tonemap_psycho22_MBFromWeightedLMS(weighted_lms_clamped);
  float y_mb = mb.z;
  if (!(y_mb > renodx_tonemap_psycho22_GAMUT_EPSILON)) {
    return float3(weighted_lms_clamped.xy, 0.0);
  }

  float2 white = renodx_tonemap_psycho22_CIE1702WhiteChromaticity();
  float2 direction = mb.xy - white;
  if (dot(direction, direction) <= renodx_tonemap_psycho22_MB_NEAR_WHITE_EPSILON) {
    return weighted_lms_clamped;
  }

  float t_clip = renodx_tonemap_psycho22_RayExitTCIE1702(white, direction);
  float t_final = min(1.0, t_clip);
  return renodx_tonemap_psycho22_WeightedLMSFromMB(white + direction * t_final, y_mb);
}

void renodx_tonemap_psycho22_MakeBT709TriangleInAdaptiveMB(
    float3 current_adaptive_state_lms, out float2 r, out float2 g, out float2 b) {
  float3 weighted_r = renodx_tonemap_psycho22_WeighLMS(
                          renodx_tonemap_psycho22_StockmanLMSFromBT709(float3(1.0, 0.0, 0.0)))
                      / current_adaptive_state_lms;
  float3 weighted_g = renodx_tonemap_psycho22_WeighLMS(
                          renodx_tonemap_psycho22_StockmanLMSFromBT709(float3(0.0, 1.0, 0.0)))
                      / current_adaptive_state_lms;
  float3 weighted_b = renodx_tonemap_psycho22_WeighLMS(
                          renodx_tonemap_psycho22_StockmanLMSFromBT709(float3(0.0, 0.0, 1.0)))
                      / current_adaptive_state_lms;

  r = renodx_tonemap_psycho22_MBFromWeightedLMS(weighted_r).xy;
  g = renodx_tonemap_psycho22_MBFromWeightedLMS(weighted_g).xy;
  b = renodx_tonemap_psycho22_MBFromWeightedLMS(weighted_b).xy;
}

float3 renodx_tonemap_psycho22_GamutCompressAdaptiveRelativeWeightedLMSBoundBT709(
    float3 relative_weighted_lms, float3 current_adaptive_state_lms, float strength) {
  float3 weighted_lms_clamped = renodx_tonemap_psycho22_ClampWeightedLMSToCIE1702(
      max(relative_weighted_lms, (float3)(0.0)));
  float3 mb = renodx_tonemap_psycho22_MBFromWeightedLMS(weighted_lms_clamped);
  float y_mb = mb.z;
  if (!(y_mb > renodx_tonemap_psycho22_GAMUT_EPSILON)) {
    return float3(weighted_lms_clamped.xy, 0.0);
  }

  float2 white = renodx_tonemap_psycho22_CIE1702WhiteChromaticity();
  float2 direction = mb.xy - white;
  if (dot(direction, direction) <= renodx_tonemap_psycho22_MB_NEAR_WHITE_EPSILON) {
    return weighted_lms_clamped;
  }

  float2 bound_r;
  float2 bound_g;
  float2 bound_b;
  renodx_tonemap_psycho22_MakeBT709TriangleInAdaptiveMB(
      current_adaptive_state_lms, bound_r, bound_g, bound_b);

  bool has_peak = false;
  float t_peak = renodx_tonemap_psycho22_RayMaxTRGBTriangleInMB(
      white, direction, bound_r, bound_g, bound_b, has_peak);
  float t_clip = renodx_tonemap_psycho22_RayExitTCIE1702(white, direction);
  if (!has_peak) {
    t_peak = t_clip;
  }

  float t_hard = clamp(t_peak, 0.0, 1.0);
  float t_soft = renodx_tonemap_psycho22_NeutwoScaleFromRayT(
      min(t_peak, t_clip), t_clip);
  float soft_mix = clamp(strength, 0.0, 1.0)
                   * renodx_tonemap_psycho22_SoftCompressionActivationFromRayT(t_peak);
  float t_final = lerp(t_hard, t_soft, soft_mix);

  return renodx_tonemap_psycho22_WeightedLMSFromMB(
      white + t_final * direction, y_mb);
}

static const float renodx_tonemap_psycho23_EPSILON = 1e-6;
static const float renodx_tonemap_psycho23_REFERENCE_SIMULTANEOUS_RANGE_LOG10 = 3.7;
static const float renodx_tonemap_psycho23_REFERENCE_CENTERED_RANGE_SIDE_COUNT = 2.0;
static const float renodx_tonemap_psycho23_HEADROOM_RATIO_FALLBACK = 1.0;
static const float renodx_tonemap_psycho23_MIN_AUTO_COMPRESSION = 1.0;

// Empirical signed-opponent appearance controls from PsychoV23.
static const float renodx_tonemap_psycho23_RED_RETENTION = 1.5;
static const float renodx_tonemap_psycho23_GREEN_RETENTION = 2.0;
static const float renodx_tonemap_psycho23_BLUE_RETENTION = 1.0;
static const float renodx_tonemap_psycho23_YELLOW_RETENTION = 3.0;

float renodx_tonemap_psycho23_YfFromLMS(float3 lms) {
  float3 weighted_lms = renodx_tonemap_psycho22_WeighLMS(lms);
  return max(weighted_lms.x + weighted_lms.y, renodx_tonemap_psycho23_EPSILON);
}

float renodx_tonemap_psycho23_AutoCompressionFromCenteredReferenceRange(
    float anchor_out_yf, float peak_yf) {
  float peak_over_anchor = renodx_color_macleod_boynton_DivideSafe(
      max(peak_yf, renodx_tonemap_psycho23_EPSILON),
      max(anchor_out_yf, renodx_tonemap_psycho23_EPSILON),
      renodx_tonemap_psycho23_HEADROOM_RATIO_FALLBACK);
  peak_over_anchor = max(
      peak_over_anchor,
      1.0 + renodx_tonemap_psycho23_EPSILON);

  float reference_one_side_range_log10 =
      renodx_tonemap_psycho23_REFERENCE_SIMULTANEOUS_RANGE_LOG10
      / renodx_tonemap_psycho23_REFERENCE_CENTERED_RANGE_SIDE_COUNT;
  float actual_above_adaptation_range_log10 = max(
      log2(peak_over_anchor) / log2(10.0),
      renodx_tonemap_psycho23_EPSILON);

  return max(
      reference_one_side_range_log10 / actual_above_adaptation_range_log10,
      renodx_tonemap_psycho23_MIN_AUTO_COMPRESSION);
}

float3 renodx_tonemap_psycho23_ToAdaptiveRelativeWeightedLMS(
    float3 lms_input, float3 current_adaptive_state_lms) {
  return renodx_tonemap_psycho22_DivideSafe(
      renodx_tonemap_psycho22_WeighLMS(lms_input),
      current_adaptive_state_lms,
      (float3)(0.0));
}

float3 renodx_tonemap_psycho23_FromAdaptiveRelativeWeightedLMS(
    float3 relative_weighted_lms, float3 current_adaptive_state_lms) {
  return relative_weighted_lms
         * max(current_adaptive_state_lms, (float3)(renodx_tonemap_psycho23_EPSILON));
}

float3 renodx_tonemap_psycho23_AdaptiveRelativeWeightedNeutral() {
  return renodx_tonemap_psycho22_WeighLMS((float3)(1.0));
}

float3 renodx_tonemap_psycho23_OpponentACCFromWeightedDelta(float3 delta_weighted_lms) {
  float3 neutral_weighted = renodx_tonemap_psycho23_AdaptiveRelativeWeightedNeutral();
  float m_to_l = renodx_color_macleod_boynton_DivideSafe(
      neutral_weighted.x,
      neutral_weighted.y,
      0.0);
  float s_to_lm = renodx_color_macleod_boynton_DivideSafe(
      neutral_weighted.x + neutral_weighted.y,
      neutral_weighted.z,
      0.0);

  return float3(
      delta_weighted_lms.x + delta_weighted_lms.y,
      delta_weighted_lms.x - m_to_l * delta_weighted_lms.y,
      -delta_weighted_lms.x - delta_weighted_lms.y
          + s_to_lm * delta_weighted_lms.z);
}

float3 renodx_tonemap_psycho23_WeightedDeltaFromOpponentACC(float3 acc) {
  float3 neutral_weighted = renodx_tonemap_psycho23_AdaptiveRelativeWeightedNeutral();
  float m_to_l = renodx_color_macleod_boynton_DivideSafe(
      neutral_weighted.x,
      neutral_weighted.y,
      0.0);
  float s_to_lm = renodx_color_macleod_boynton_DivideSafe(
      neutral_weighted.x + neutral_weighted.y,
      neutral_weighted.z,
      0.0);

  float delta_m = renodx_color_macleod_boynton_DivideSafe(
      acc.x - acc.y,
      1.0 + m_to_l,
      0.0);
  float delta_l = acc.x - delta_m;
  float delta_s = renodx_color_macleod_boynton_DivideSafe(
      acc.z + acc.x,
      s_to_lm,
      0.0);
  return float3(delta_l, delta_m, delta_s);
}

float renodx_tonemap_psycho23_SignedOpponentRetention(
    float white_progress, float retention_exponent) {
  return 1.0 - pow(
                   clamp(white_progress, 0.0, 1.0),
                   max(retention_exponent, renodx_tonemap_psycho23_EPSILON));
}

float3 renodx_tonemap_psycho23_ApplySignedOpponentRetention(
    float3 compressed_lms,
    float3 source_lms,
    float3 adaptive_state_lms,
    float3 peak_lms,
    float white_progress) {
  if (white_progress <= 0.0
      || min(source_lms.x, min(source_lms.y, source_lms.z)) <= 0.0) {
    return compressed_lms;
  }

  float3 source_weighted = renodx_tonemap_psycho23_ToAdaptiveRelativeWeightedLMS(
      source_lms,
      adaptive_state_lms);
  float3 adapted_neutral = renodx_tonemap_psycho23_AdaptiveRelativeWeightedNeutral();
  float adapted_neutral_yf = adapted_neutral.x + adapted_neutral.y;
  float source_yf = source_weighted.x + source_weighted.y;

  if (source_yf <= renodx_tonemap_psycho23_EPSILON
      || adapted_neutral_yf <= renodx_tonemap_psycho23_EPSILON) {
    return compressed_lms;
  }

  float3 source_neutral = adapted_neutral
                          * renodx_color_macleod_boynton_DivideSafe(
                              source_yf,
                              adapted_neutral_yf,
                              1.0);
  float3 source_acc = renodx_tonemap_psycho23_OpponentACCFromWeightedDelta(
                          source_weighted - source_neutral)
                      / source_yf;

  float red_retention = renodx_tonemap_psycho23_SignedOpponentRetention(
      white_progress,
      renodx_tonemap_psycho23_RED_RETENTION);
  float green_retention = renodx_tonemap_psycho23_SignedOpponentRetention(
      white_progress,
      renodx_tonemap_psycho23_GREEN_RETENTION);
  float blue_retention = renodx_tonemap_psycho23_SignedOpponentRetention(
      white_progress,
      renodx_tonemap_psycho23_BLUE_RETENTION);
  float yellow_retention = renodx_tonemap_psycho23_SignedOpponentRetention(
      white_progress,
      renodx_tonemap_psycho23_YELLOW_RETENTION);

  float rg_out = max(source_acc.y, 0.0) * red_retention
                 - max(-source_acc.y, 0.0) * green_retention;
  float yv_out = max(source_acc.z, 0.0) * blue_retention
                 - max(-source_acc.z, 0.0) * yellow_retention;

  float3 compressed_weighted = renodx_tonemap_psycho23_ToAdaptiveRelativeWeightedLMS(
      compressed_lms,
      adaptive_state_lms);
  float target_yf = compressed_weighted.x + compressed_weighted.y;
  if (target_yf <= renodx_tonemap_psycho23_EPSILON) {
    return compressed_lms;
  }

  float3 peak_weighted = renodx_tonemap_psycho23_ToAdaptiveRelativeWeightedLMS(
      peak_lms,
      adaptive_state_lms);
  float peak_weighted_yf = peak_weighted.x + peak_weighted.y;
  if (peak_weighted_yf <= renodx_tonemap_psycho23_EPSILON) {
    return compressed_lms;
  }

  float3 target_neutral = peak_weighted
                          * renodx_color_macleod_boynton_DivideSafe(
                              target_yf,
                              peak_weighted_yf,
                              1.0);
  float3 target_delta = renodx_tonemap_psycho23_WeightedDeltaFromOpponentACC(
      float3(0.0, rg_out * target_yf, yv_out * target_yf));
  float3 output_lms = renodx_tonemap_psycho22_UnweighLMS(
      renodx_tonemap_psycho23_FromAdaptiveRelativeWeightedLMS(
          target_neutral + target_delta,
          adaptive_state_lms));

  float compressed_yf = renodx_tonemap_psycho23_YfFromLMS(compressed_lms);
  float output_yf = renodx_tonemap_psycho23_YfFromLMS(output_lms);
  if (output_yf <= renodx_tonemap_psycho23_EPSILON) {
    return compressed_lms;
  }

  return output_lms
         * renodx_color_macleod_boynton_DivideSafe(
             compressed_yf,
             output_yf,
             1.0);
}

float3 renodx_tonemap_psycho23_ApplySignedOpponentRetentionAndGamutCompressionLMS(
    float3 precompression_lms,
    float3 compressed_lms,
    float3 input_adaptive_state_lms,
    float3 output_anchor_lms,
    float3 peak_white_lms,
    float hue_restore,
    float gamut_compression) {
  float anchor_yf = renodx_tonemap_psycho23_YfFromLMS(output_anchor_lms);
  float peak_yf = renodx_tonemap_psycho23_YfFromLMS(peak_white_lms);
  float output_yf = renodx_tonemap_psycho23_YfFromLMS(compressed_lms);

  // Measure white convergence from the actual compressed output because the
  // RDR2 shoulder is Neutwo rather than PsychoV's analytic compression curve.
  float compression_power = renodx_tonemap_psycho23_AutoCompressionFromCenteredReferenceRange(
      anchor_yf,
      peak_yf);
  float anchor_over_peak = clamp(
      renodx_color_macleod_boynton_DivideSafe(anchor_yf, peak_yf, 1.0),
      0.0,
      1.0);
  float output_over_peak = max(
      renodx_color_macleod_boynton_DivideSafe(output_yf, peak_yf, 0.0),
      0.0);
  float anchor_powered = pow(
      max(anchor_over_peak, renodx_tonemap_psycho23_EPSILON),
      compression_power);
  float white_progress = clamp(
      renodx_color_macleod_boynton_DivideSafe(
          pow(output_over_peak, compression_power) - anchor_powered,
          1.0 - anchor_powered,
          0.0),
      0.0,
      1.0);

  float3 opponent_retained_lms = renodx_tonemap_psycho23_ApplySignedOpponentRetention(
      compressed_lms,
      precompression_lms,
      input_adaptive_state_lms,
      peak_white_lms,
      white_progress);
  float3 hue_restored_lms = lerp(
      compressed_lms,
      opponent_retained_lms,
      clamp(hue_restore, 0.0, 1.0));

  float3 display_relative_weighted = renodx_tonemap_psycho23_ToAdaptiveRelativeWeightedLMS(
      hue_restored_lms,
      input_adaptive_state_lms);
  if (gamut_compression != 0.0) {
    display_relative_weighted = renodx_tonemap_psycho22_GamutCompressAdaptiveRelativeWeightedLMSBoundBT709(
        display_relative_weighted,
        input_adaptive_state_lms,
        gamut_compression);
  }

  return renodx_tonemap_psycho22_UnweighLMS(
      renodx_tonemap_psycho23_FromAdaptiveRelativeWeightedLMS(
          display_relative_weighted,
          input_adaptive_state_lms));
}

float3 renodx_tonemap_psycho22_GamutCompressBT709(
    float3 bt709, float3 current_adaptive_state_bt709, float strength) {
  float3 current_adaptive_state_lms = renodx_tonemap_psycho22_StockmanLMSFromBT709(
      current_adaptive_state_bt709);
  float3 relative_weighted_lms = renodx_tonemap_psycho22_DivideSafe(
      renodx_tonemap_psycho22_WeighLMS(
          renodx_tonemap_psycho22_StockmanLMSFromBT709(bt709)),
      current_adaptive_state_lms,
      (float3)(0.0));

  relative_weighted_lms = renodx_tonemap_psycho22_GamutCompressAdaptiveRelativeWeightedLMSBoundBT709(
      relative_weighted_lms,
      current_adaptive_state_lms,
      strength);

  float3 output_lms = renodx_tonemap_psycho22_UnweighLMS(
      relative_weighted_lms * max(current_adaptive_state_lms, (float3)(1e-6)));
  return renodx_tonemap_psycho22_BT709FromStockmanLMS(output_lms);
}

#endif  // SRC_GAMES_RDR2DX12_PERCEPTUAL_COLOR_HLSLI_
