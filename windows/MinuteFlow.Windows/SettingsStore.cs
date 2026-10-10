using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using MinuteFlow.Core;

namespace MinuteFlow.Windows;

public sealed class SettingsStore
{
    public string Root { get; }
    public ModelConfiguration Configuration { get; private set; }
    public string CredentialError { get; private set; } = "";
    public event Action? Changed;
    public SettingsStore(string root)
    {
        Root = root; Directory.CreateDirectory(root);
        var file = Path.Combine(root, "settings.json");
        try { Configuration = File.Exists(file) ? JsonSerializer.Deserialize<ModelConfiguration>(File.ReadAllText(file), MeetingRepository.Json) ?? new() : new(); }
        catch (Exception e) when (e is JsonException or IOException) { Configuration = new(); CredentialError = "设置文件无法读取，请重新保存设置。"; }
        try { if (File.Exists(TokenFile)) Configuration.Token = Encoding.UTF8.GetString(WindowsCredentialProtection.Unprotect(File.ReadAllBytes(TokenFile))); }
        catch { CredentialError = "无法解密保存的 Token。请使用原 Windows 用户登录，或重新填写 Token。"; }
    }
    private string TokenFile => Path.Combine(Root, "credential.dpapi");
    public void Save(ModelConfiguration configuration, string replacementToken)
    {
        configuration.Token = Configuration.Token;
        if (!string.IsNullOrWhiteSpace(replacementToken))
        {
            var encrypted = WindowsCredentialProtection.Protect(Encoding.UTF8.GetBytes(replacementToken.Trim()));
            var recovered = Encoding.UTF8.GetString(WindowsCredentialProtection.Unprotect(encrypted));
            if (recovered != replacementToken.Trim()) throw new IOException("Token 保存回读失败。");
            var temporary = TokenFile + ".tmp";
            File.WriteAllBytes(temporary, encrypted); File.Move(temporary, TokenFile, true);
            configuration.Token = recovered;
        }
        MeetingRepository.WriteIfChanged(Path.Combine(Root, "settings.json"), JsonSerializer.Serialize(configuration, MeetingRepository.Json));
        Configuration = configuration; CredentialError = ""; Changed?.Invoke();
    }
    public void ClearToken()
    {
        if (File.Exists(TokenFile)) File.Delete(TokenFile);
        Configuration.Token = ""; Changed?.Invoke();
    }
}

internal static class WindowsCredentialProtection
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static byte[] Protect(byte[] bytes) => Transform(bytes, true);
    public static byte[] Unprotect(byte[] bytes) => Transform(bytes, false);
    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new Blob { Size = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) }; Blob output = default;
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            var success = protect ? CryptProtectData(ref input, "MinuteFlow API credential", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!success) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally { Marshal.FreeHGlobal(input.Data); if (output.Data != IntPtr.Zero) LocalFree(output.Data); }
    }
}
