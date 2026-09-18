// Compile-only helper coverage. Not an RDR2 replacement: no game bindings/hash.
#include "../src/games/rdr2dx12/tonemap/tonemap.hlsli"
#include "../src/games/rdr2dx12/output/output.hlsli"

float4 main(float4 position : SV_Position, float3 color : TEXCOORD0) : SV_Target0 {
  float3 graded = ApplyGradingAndDisplayMap(color, position.xy);
  return float4(PQEncodeUI(BT2020FromBT709(graded)), 1.0);
}
