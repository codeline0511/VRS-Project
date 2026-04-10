using System;
using OpenTK.Mathematics;
using BBOpenGL;
using IDKEngine.Utils;

namespace IDKEngine.Render;

class MotionAwareVRSClassifier : IDisposable
{
    public const int TILE_SIZE = 16;

    public static readonly bool IS_SUPPORTED = BBG.GetDeviceInfo().ExtensionSupport.VariableRateShading;

    // Keep in sync between shader and client code!
    public enum DebugMode : int
    {
        None,
        ShadingRate,
        Motion,
        Luminance,
        LuminanceVariance,
        DepthRange,
        Foveated,
    }

    public record struct GpuSettings
    {
        public DebugMode DebugValue = DebugMode.None;

        // motion thresholds
        public float MotionLow = 0.75f;
        public float MotionHigh = 2.0f;

        // variance thresholds
        public float LumaVarianceLow = 0.0008f;
        public float LumaVarianceHigh = 0.0040f;

        // depth discontinuity protection
        public float DepthRangeThreshold = 0.01f;

        // foveated
        public Vector2 MousePos;
        public int IsFoveated;
        public float InnerRadius;
        public float MiddleRadius;

        // coarse rate enable flags
        public int Allow2x2;
        public int Allow4x2;
        public int Allow4x4;

        // bias / tuning
        public float MotionBias;
        public float VarianceBias;
        public float _Pad0;

        public GpuSettings()
        {
            DebugValue = DebugMode.None;

            MotionLow = 0.75f;
            MotionHigh = 2.0f;

            LumaVarianceLow = 0.0008f;
            LumaVarianceHigh = 0.0040f;

            DepthRangeThreshold = 0.01f;

            MousePos = new Vector2(0.5f, 0.5f);
            IsFoveated = 1;
            InnerRadius = 0.18f;
            MiddleRadius = 0.38f;

            Allow2x2 = 1;
            Allow4x2 = 1;
            Allow4x4 = 0;

            MotionBias = 1.0f;
            VarianceBias = 1.0f;
            _Pad0 = 0.0f;
        }
    }

    public GpuSettings Settings;
    public BBG.Rendering.ShadingRateNV[] ShadingRatePalette;

    public BBG.Texture Result;
    private BBG.Texture debugTexture;
    private readonly BBG.AbstractShaderProgram shaderProgram;
    private readonly BBG.AbstractShaderProgram debugProgram;

    public MotionAwareVRSClassifier(Vector2i size, in GpuSettings settings)
    {
        shaderProgram = new BBG.AbstractShaderProgram(
            BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionAwareVRSClassification/compute.glsl"));

        debugProgram = new BBG.AbstractShaderProgram(
            BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "MotionAwareVRSClassification/debugCompute.glsl"));

        SetSize(size);

        ShadingRatePalette =
        [
            BBG.Rendering.ShadingRateNV._1InvocationPerPixel,
            BBG.Rendering.ShadingRateNV._1InvocationPer2x1Pixels,
            BBG.Rendering.ShadingRateNV._1InvocationPer2x2Pixels,
            BBG.Rendering.ShadingRateNV._1InvocationPer4x2Pixels,
            BBG.Rendering.ShadingRateNV._1InvocationPer4x4Pixels
        ];

        Settings = settings;
    }

    public void Compute(BBG.Texture shaded)
    {
        BBG.Computing.Compute("Generate Motion Aware Shading Rate Image", () =>
        {
            BBG.Cmd.SetUniforms(Settings);

            BBG.Cmd.BindImageUnit(Result, 0);
            BBG.Cmd.BindImageUnit(debugTexture, 1);
            BBG.Cmd.BindTextureUnit(shaded, 0);
            BBG.Cmd.UseShaderProgram(shaderProgram);

            BBG.Computing.Dispatch(
                MyMath.DivUp(shaded.Width, TILE_SIZE),
                MyMath.DivUp(shaded.Height, TILE_SIZE),
                1);

            BBG.Cmd.MemoryBarrier(BBG.Cmd.MemoryBarrierMask.TextureFetchBarrierBit);
        });
    }

    public void DebugRender(BBG.Texture dest)
    {
        if (Settings.DebugValue == DebugMode.None)
        {
            return;
        }

        BBG.Computing.Compute("Debug render motion aware shading rate attributes", () =>
        {
            BBG.Cmd.SetUniforms(Settings);

            BBG.Cmd.BindImageUnit(dest, 0);
            BBG.Cmd.BindTextureUnit(dest, 0);
            BBG.Cmd.BindTextureUnit(Settings.DebugValue == DebugMode.ShadingRate ? Result : debugTexture, 1);

            BBG.Cmd.UseShaderProgram(debugProgram);
            BBG.Computing.Dispatch(MyMath.DivUp(dest.Width, TILE_SIZE), MyMath.DivUp(dest.Height, TILE_SIZE), 1);
            BBG.Cmd.MemoryBarrier(BBG.Cmd.MemoryBarrierMask.TextureFetchBarrierBit);
        });
    }

    public void SetSize(Vector2i size)
    {
        size.X = (int)MathF.Ceiling((float)size.X / TILE_SIZE);
        size.Y = (int)MathF.Ceiling((float)size.Y / TILE_SIZE);

        if (Result != null) Result.Dispose();
        Result = new BBG.Texture(BBG.Texture.Type.Texture2D);
        Result.SetFilter(BBG.Sampler.MinFilter.Nearest, BBG.Sampler.MagFilter.Nearest);
        Result.Allocate(size.X, size.Y, 1, BBG.Texture.InternalFormat.R8UInt);

        if (debugTexture != null) debugTexture.Dispose();
        debugTexture = new BBG.Texture(BBG.Texture.Type.Texture2D);
        debugTexture.SetFilter(BBG.Sampler.MinFilter.Nearest, BBG.Sampler.MagFilter.Nearest);
        debugTexture.Allocate(Result.Width, Result.Height, 1, BBG.Texture.InternalFormat.R32Float);
    }

    public BBG.Rendering.VariableRateShadingNV GetRenderData()
    {
        return new BBG.Rendering.VariableRateShadingNV()
        {
            ShadingRateImage = Result,
            ShadingRatePalette = ShadingRatePalette,
        };
    }

    public void Dispose()
    {
        Result.Dispose();
        debugTexture.Dispose();
        shaderProgram.Dispose();
        debugProgram.Dispose();
    }
}