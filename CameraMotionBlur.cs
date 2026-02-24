using System;
using OpenTK.Mathematics;
using BBOpenGL;
using IDKEngine.Utils;

namespace IDKEngine.Render;

class CameraMotionBlur : IDisposable
{
    public record struct GpuSettings
    {
        public float Strength = 1.0f;
        public float MaxBlurPixels = 16.0f;
        public int Samples = 12;
        public int HasDepth = 1;

        public Matrix4 PrevProjView;
        public Matrix4 InvProjView;

        public GpuSettings() { }
    }

    public GpuSettings Settings;

    public BBG.Texture Result;
    private readonly BBG.AbstractShaderProgram program;

    public CameraMotionBlur(Vector2i size)
    {
        program = new BBG.AbstractShaderProgram(
            BBG.AbstractShader.FromFile(BBG.ShaderStage.Compute, "CameraMotionBlur/compute.glsl")
        );

        SetSize(size);
        Settings = new GpuSettings();
    }

    public void SetSize(Vector2i size)
    {
        Result?.Dispose();
        Result = new BBG.Texture(BBG.Texture.Type.Texture2D);
        Result.SetFilter(BBG.Sampler.MinFilter.Linear, BBG.Sampler.MagFilter.Linear);
        Result.SetWrapMode(BBG.Sampler.WrapMode.ClampToEdge, BBG.Sampler.WrapMode.ClampToEdge);
        Result.Allocate(size.X, size.Y, 1, BBG.Texture.InternalFormat.R8G8B8A8Unorm);
    }

    public void Compute(BBG.Texture inputColor, BBG.Texture depthOrNull,  Matrix4 prevProjView, Matrix4 invProjView)
    {
        BBG.Computing.Compute("Camera Motion Blur", () =>
        {
            Settings.PrevProjView = prevProjView;
            Settings.InvProjView = invProjView;
            Settings.HasDepth = (depthOrNull != null) ? 1 : 0;

            BBG.Cmd.UseShaderProgram(program);
            BBG.Cmd.SetUniforms(Settings);

            BBG.Cmd.BindImageUnit(Result, 0);
            BBG.Cmd.BindTextureUnit(inputColor, 0, inputColor != null);
            BBG.Cmd.BindTextureUnit(depthOrNull, 1, depthOrNull != null);

            BBG.Computing.Dispatch(MyMath.DivUp(Result.Width, 8), MyMath.DivUp(Result.Height, 8), 1);
            BBG.Cmd.MemoryBarrier(BBG.Cmd.MemoryBarrierMask.TextureFetchBarrierBit);
        });
    }

    public void Dispose()
    {
        Result?.Dispose();
        program?.Dispose();
    }
}
