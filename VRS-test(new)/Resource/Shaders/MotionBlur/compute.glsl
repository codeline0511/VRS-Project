#version 460 core

AppInclude(include/StaticUniformBuffers.glsl)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(binding = 0) restrict writeonly uniform image2D ImgResult;
layout(binding = 0) uniform sampler2D SamplerSrc;

layout(std140, binding = 0) uniform SettingsUBO
{
    int   SampleCount;
    float Intensity;
    float MaxBlurPixels;

    float DeltaTime;
    float ReferenceDeltaTime;
    float ShutterScale;
    float MinDeltaScale;
    float MaxDeltaScale;
} settingsUBO;

void main()
{
    ivec2 imgCoord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 outSizeI = imageSize(ImgResult);

    if (imgCoord.x >= outSizeI.x || imgCoord.y >= outSizeI.y)
    {
        return;
    }

    vec2 imgSize = vec2(outSizeI);
    vec2 uv = (vec2(imgCoord) + 0.5) / imgSize;

    vec3 srcColor = textureLod(SamplerSrc, uv, 0).rgb;

    // GBuffer velocity
    vec2 velocity = texelFetch(gBufferDataUBO.Velocity, imgCoord, 0).rg;

    float safeRefDt = max(settingsUBO.ReferenceDeltaTime, 1e-6);
    float dtScale = settingsUBO.DeltaTime / safeRefDt;
    dtScale = clamp(dtScale, settingsUBO.MinDeltaScale, settingsUBO.MaxDeltaScale);

    float shutterScale = max(settingsUBO.ShutterScale, 0.0);

    vec2 blurVec = velocity * settingsUBO.Intensity * dtScale * shutterScale;

    float pixelLen = length(blurVec * imgSize);
    if (pixelLen < 1e-6)
    {
        imageStore(ImgResult, imgCoord, vec4(srcColor, 1.0));
        return;
    }

    if (pixelLen > settingsUBO.MaxBlurPixels)
    {
        blurVec *= settingsUBO.MaxBlurPixels / pixelLen;
        pixelLen = settingsUBO.MaxBlurPixels;
    }

    int sampleCount = max(settingsUBO.SampleCount, 2);

    vec3 colorSum = vec3(0.0);
    float weightSum = 0.0;

    for (int i = 0; i < sampleCount; i++)
    {
        float t = (float(i) / float(sampleCount - 1)) - 0.5;
        vec2 sampleUV = clamp(uv + blurVec * t, vec2(0.0), vec2(1.0));

        float weight = 1.0 - abs(t) * 2.0;
        weight = max(weight, 0.001);

        colorSum += textureLod(SamplerSrc, sampleUV, 0).rgb * weight;
        weightSum += weight;
    }

    vec3 outColor = colorSum / max(weightSum, 1e-6);
    imageStore(ImgResult, imgCoord, vec4(outColor, 1.0));
}