#include <metal_stdlib>
using namespace metal;

// Inverse of CurvedTrack.point: find the centerline normal through this pixel,
// then sample the straight SF Symbol at that normal's offset and track height.
[[ stitchable ]] float2 curvedSwitcherSymbol(float2 position, float4 track, float sourceCenterX) {
    float y = position.y;
    for (int iteration = 0; iteration < 4; ++iteration) {
        float phase = track.w * (y - track.z);
        float centerX = track.x + track.y * cos(phase);
        float slope = -track.y * track.w * sin(phase);
        float curvature = -track.y * track.w * track.w * cos(phase);
        float dx = position.x - centerX;
        float error = y - position.y - dx * slope;
        y -= error / (1.0 + slope * slope - dx * curvature);
    }
    float phase = track.w * (y - track.z);
    float centerX = track.x + track.y * cos(phase);
    float slope = -track.y * track.w * sin(phase);
    float offsetX = (position.x - centerX) * sqrt(1.0 + slope * slope);
    return float2(sourceCenterX + offsetX, y);
}
