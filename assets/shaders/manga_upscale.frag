#version 460 core
#include <flutter/runtime_effect.glsl>

// 漫画图片超分（实时 GPU 单趟后处理）：双三次 Catmull-Rom 放大 + 对比度自适应锐化。
//
// 为什么不是 AI 模型：Flutter 的 FragmentProgram 是单趟后处理，承载不了 Anime4K
// 那类多趟 CNN 推理。本 shader 走「高质量重采样 + 边缘自适应锐化」路线：
// 放大用 Catmull-Rom（比默认双线性明显更锐、无块状），再叠加 RCAS（Radeon
// Contrast Adaptive Sharpening）风格锐化——平坦区轻锐化、强边缘自动收敛，
// 避免漫画网点/线条出现白边与振铃。
//
// uniform 约定（顺序即 setFloat 索引）：
//   sampler2D uImage   : 源图（Dart 侧 setImageSampler(0, image)）
//   vec2 uSrcSize      : 源图像素尺寸
//   vec2 uDstSize      : 目标绘制尺寸（逻辑像素）
//   float uMode        : 0 = 仅重采样；1 = 重采样 + 自适应锐化
//   float uSharp       : 锐化强度 0.0–1.0（uMode=1 时生效）

uniform sampler2D uImage;
uniform vec2 uSrcSize;
uniform vec2 uDstSize;
uniform float uMode;
uniform float uSharp;

out vec4 fragColor;

float luma(vec3 c) {
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 fetch(vec2 uv) {
  return texture(uImage, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

/// 边界夹取的 alpha 采样（避免图像边缘采到图外透明像素造成黑边）。
float fetchAlpha(vec2 uv) {
  return texture(uImage, clamp(uv, vec2(0.0), vec2(1.0))).a;
}

// Catmull-Rom 权重（t ∈ [0,1)，返回 4 个抽头权重）。
vec4 crWeights(float t) {
  float t2 = t * t;
  float t3 = t2 * t;
  return vec4(
      -0.5 * t3 + t2 - 0.5 * t,
      1.5 * t3 - 2.5 * t2 + 1.0,
      -1.5 * t3 + 2.0 * t2 + 0.5 * t,
      0.5 * t3 - 0.5 * t2);
}

// 分离式 4x4 双三次采样（16 抽头展开，避免动态索引）。
//
// 相位说明（易错点）：`coord = uv/texel - 0.5` 把 uv 转成「以像素中心为整数点」
// 的坐标——像素 i 的中心恰好落在 coord = i。Catmull-Rom 的 4 个抽头相对 base 的
// 位置是 -1/0/+1/+2，对应的像素中心因此是 base-1、base、base+1、base+2，
// 即 uv 偏移 (base-0.5)、(base+0.5)、(base+1.5)、(base+2.5) 乘以 texel。
// 若错写成 (base+0.5)…(base+3.5)，整幅图会右/下平移一个像素并整体发虚。
vec3 bicubic(vec2 uv, vec2 texel) {
  vec2 coord = uv / texel - 0.5;
  vec2 base = floor(coord);
  vec2 f = coord - base;
  vec4 wx = crWeights(f.x);
  vec4 wy = crWeights(f.y);

  vec2 o0 = (base - vec2(0.5, 0.5)) * texel;
  vec2 o1 = (base + vec2(0.5, 0.5)) * texel;
  vec2 o2 = (base + vec2(1.5, 1.5)) * texel;
  vec2 o3 = (base + vec2(2.5, 2.5)) * texel;

  vec2 t0 = vec2(0.0, texel.y);

  vec3 r0 = fetch(o0) * wx.x + fetch(o1) * wx.y + fetch(o2) * wx.z + fetch(o3) * wx.w;
  vec3 r1 = fetch(o0 + t0) * wx.x + fetch(o1 + t0) * wx.y + fetch(o2 + t0) * wx.z + fetch(o3 + t0) * wx.w;
  vec3 r2 = fetch(o0 + t0 * 2.0) * wx.x + fetch(o1 + t0 * 2.0) * wx.y + fetch(o2 + t0 * 2.0) * wx.z + fetch(o3 + t0 * 2.0) * wx.w;
  vec3 r3 = fetch(o0 + t0 * 3.0) * wx.x + fetch(o1 + t0 * 3.0) * wx.y + fetch(o2 + t0 * 3.0) * wx.z + fetch(o3 + t0 * 3.0) * wx.w;

  return r0 * wy.x + r1 * wy.y + r2 * wy.z + r3 * wy.w;
}

// RCAS 风格自适应锐化：按四邻域对比度限制锐化量，抑制边缘过冲。
vec3 adaptiveSharpen(vec2 uv, vec2 texel, vec3 center, float amount) {
  vec3 n = fetch(uv + vec2(0.0, -texel.y));
  vec3 s = fetch(uv + vec2(0.0, texel.y));
  vec3 w = fetch(uv - vec2(texel.x, 0.0));
  vec3 e = fetch(uv + vec2(texel.x, 0.0));

  float lc = luma(center);
  float lmin = min(lc, min(min(luma(n), luma(s)), min(luma(w), luma(e))));
  float lmax = max(lc, max(max(luma(n), luma(s)), max(luma(w), luma(e))));

  // 对比度越低 → 允许锐化越强；强边缘（对比度接近 1）直接收敛到 0。
  float contrast = clamp((lmax - lmin) * 4.0, 0.0, 1.0);
  float gain = amount * (1.0 - contrast);

  vec3 blur = (n + s + w + e) * 0.25;
  return center + (center - blur) * gain * 2.0;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 dst = max(uDstSize, vec2(1.0));
  vec2 src = max(uSrcSize, vec2(1.0));
  vec2 uv = frag / dst;
  vec2 texel = 1.0 / src;

  // 缩小显示：双三次会引入不必要模糊，交回默认硬采样。
  if (dst.x < src.x || dst.y < src.y) {
    vec4 c = texture(uImage, uv);
    fragColor = c;
    return;
  }

  vec3 color = bicubic(uv, texel);
  if (uMode > 0.5 && uSharp > 0.0) {
    color = adaptiveSharpen(uv, texel, color, clamp(uSharp, 0.0, 1.0));
  }
  // alpha 同样按边界夹取采样：直接用未夹取的 uv 会在图像边缘采到图外的
  // 透明像素，PNG（带透明通道的漫画页）边缘会出现一圈发虚的黑边。
  float alpha = fetchAlpha(uv);
  fragColor = vec4(clamp(color, 0.0, 1.0), alpha);
}
