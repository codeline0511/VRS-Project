#version 460 core

AppInclude(include/StaticUniformBuffers.glsl)
AppInclude(ShadingRateClassification/include/Constants.glsl)

layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

layout(binding = 0, r8ui) restrict writeonly uniform uimage2D ImgResult;
layout(binding = 1, r32f) restrict writeonly uniform image2D ImgDebug;

layout(binding = 0) uniform sampler2D SamplerShaded;

layout(std140, binding = 0) uniform SettingsUBO
{
    int   DebugValue;

    float MotionLow;
    float MotionHigh;

    float LumaVarianceLow;
    float LumaVarianceHigh;

    float DepthRangeThreshold;

    vec2  MousePos;
    int   IsFoveated;
    float InnerRadius;
    float MiddleRadius;

    int   Allow2x2;
    int   Allow4x2;
    int   Allow4x4;

    float MotionBias;
    float VarianceBias;
    float _Pad0;
} settingsUBO;

shared float SharedSpeed[256];
shared float SharedLuma[256];
shared float SharedLumaSq[256];
shared float SharedDepthMin[256];
shared float SharedDepthMax[256];

float GetLuminance(vec3 color)
{
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

uint GetRateFromIndex(int idx)
{
    if (idx <= 0) return ENUM_SHADING_RATE_1_INVOCATION_PER_PIXEL_NV;
    if (idx == 1) return ENUM_SHADING_RATE_1_INVOCATION_PER_2X1_PIXELS_NV;
    if (idx == 2) return ENUM_SHADING_RATE_1_INVOCATION_PER_2X2_PIXELS_NV;
    if (idx == 3) return ENUM_SHADING_RATE_1_INVOCATION_PER_4X2_PIXELS_NV;
    return ENUM_SHADING_RATE_1_INVOCATION_PER_4X4_PIXELS_NV;
}

int RateIndex1x1() { return 0; }
int RateIndex2x2() { return 2; }
int RateIndex4x2() { return 3; }
int RateIndex4x4() { return 4; }

int BetterQualityRate(int a, int b)
{
    return min(a, b);
}

void main()
{
    ivec2 fullRes = textureSize(SamplerShaded, 0);
    ivec2 pixelCoord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 localCoord = ivec2(gl_LocalInvocationID.xy);
    ivec2 groupCoord = ivec2(gl_WorkGroupID.xy);

    int localIndex = localCoord.y * TILE_SIZE + localCoord.x;

    bool inBounds = pixelCoord.x < fullRes.x && pixelCoord.y < fullRes.y;

    float luma = 0.0;
    float speed = 0.0;
    float depth = 1.0;

    if (inBounds)
    {
        vec3 color = texelFetch(SamplerShaded, pixelCoord, 0).rgb;
        luma = GetLuminance(color);

        vec2 velocity = texelFetch(gBufferDataUBO.Velocity, pixelCoord, 0).rg;
        speed = length(velocity * vec2(fullRes));

        depth = texelFetch(gBufferDataUBO.Depth, pixelCoord, 0).r;
    }

    SharedSpeed[localIndex] = speed;
    SharedLuma[localIndex] = luma;
    SharedLumaSq[localIndex] = luma * luma;
    SharedDepthMin[localIndex] = inBounds ? depth : 1.0;
    SharedDepthMax[localIndex] = inBounds ? depth : 0.0;

    barrier();

    for (int stride = 128; stride > 0; stride >>= 1)
    {
        if (localIndex < stride)
        {
            SharedSpeed[localIndex] += SharedSpeed[localIndex + stride];
            SharedLuma[localIndex] += SharedLuma[localIndex + stride];
            SharedLumaSq[localIndex] += SharedLumaSq[localIndex + stride];
            SharedDepthMin[localIndex] = min(SharedDepthMin[localIndex], SharedDepthMin[localIndex + stride]);
            SharedDepthMax[localIndex] = max(SharedDepthMax[localIndex], SharedDepthMax[localIndex + stride]);
        }

        barrier();
    }

    if (localIndex == 0)
    {
        float invSamples = 1.0 / float(TILE_SIZE * TILE_SIZE);

        float avgSpeed = SharedSpeed[0] * invSamples;
        float avgLuma = SharedLuma[0] * invSamples;
        float avgLumaSq = SharedLumaSq[0] * invSamples;
        float lumaVariance = max(avgLumaSq - avgLuma * avgLuma, 0.0);

        float depthRange = SharedDepthMax[0] - SharedDepthMin[0];

        float motionMetric = avgSpeed * settingsUBO.MotionBias;
        float varianceMetric = lumaVariance * settingsUBO.VarianceBias;

        bool protectDepth = depthRange > settingsUBO.DepthRangeThreshold;
        bool protectVariance = varianceMetric > settingsUBO.LumaVarianceHigh;

        int dynamicRate = RateIndex1x1();

        if (protectDepth || protectVariance)
        {
            dynamicRate = RateIndex1x1();
        }
        else if (motionMetric >= settingsUBO.MotionHigh && varianceMetric <= settingsUBO.LumaVarianceLow)
        {
            if (settingsUBO.Allow4x4 != 0)
            {
                dynamicRate = RateIndex4x4();
            }
            else if (settingsUBO.Allow4x2 != 0)
            {
                dynamicRate = RateIndex4x2();
            }
            else if (settingsUBO.Allow2x2 != 0)
            {
                dynamicRate = RateIndex2x2();
            }
            else
            {
                dynamicRate = RateIndex1x1();
            }
        }
        else if (motionMetric >= settingsUBO.MotionLow || varianceMetric <= settingsUBO.LumaVarianceHigh)
        {
            dynamicRate = settingsUBO.Allow2x2 != 0 ? RateIndex2x2() : RateIndex1x1();
        }
        else
        {
            dynamicRate = RateIndex1x1();
        }

        int foveatedRate = RateIndex1x1();

        if (settingsUBO.IsFoveated != 0)
        {
            vec2 tileCenterPx = vec2(groupCoord * TILE_SIZE) + vec2(TILE_SIZE * 0.5);
            vec2 tileCenterUv = tileCenterPx / vec2(fullRes);

            float distToFocus = distance(tileCenterUv, settingsUBO.MousePos);

            if (distToFocus <= settingsUBO.InnerRadius)
            {
                foveatedRate = RateIndex1x1();
            }
            else if (distToFocus <= settingsUBO.MiddleRadius)
            {
                foveatedRate = RateIndex2x2();
            }
            else
            {
                if (settingsUBO.Allow4x2 != 0)
                {
                    foveatedRate = RateIndex4x2();
                }
                else if (settingsUBO.Allow2x2 != 0)
                {
                    foveatedRate = RateIndex2x2();
                }
                else
                {
                    foveatedRate = RateIndex1x1();
                }
            }
        }

        int finalRate = BetterQualityRate(dynamicRate, foveatedRate);

        imageStore(ImgResult, groupCoord, uvec4(GetRateFromIndex(finalRate), 0, 0, 0));

        float debugValue = 0.0;
        if (settingsUBO.DebugValue == 1)
        {
            debugValue = float(finalRate);
        }
        else if (settingsUBO.DebugValue == 2)
        {
            debugValue = motionMetric;
        }
        else if (settingsUBO.DebugValue == 3)
        {
            debugValue = avgLuma;
        }
        else if (settingsUBO.DebugValue == 4)
        {
            debugValue = varianceMetric;
        }
        else if (settingsUBO.DebugValue == 5)
        {
            debugValue = depthRange;
        }
        else if (settingsUBO.DebugValue == 6)
        {
            vec2 tileCenterPx = vec2(groupCoord * TILE_SIZE) + vec2(TILE_SIZE * 0.5);
            vec2 tileCenterUv = tileCenterPx / vec2(fullRes);
            debugValue = distance(tileCenterUv, settingsUBO.MousePos);
        }

        imageStore(ImgDebug, groupCoord, vec4(debugValue, 0.0, 0.0, 0.0));
    }
}