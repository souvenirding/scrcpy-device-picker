using System.IO;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>
/// devices.json 读写器（移植自 Go 版 internal/config）。
/// 位置：%APPDATA%\ScrcpyPicker\devices.json，可用 SCRCPY_CONFIG_DIR 覆盖（测试就靠这个隔离）。
/// 键名与 PowerShell / Go / Swift 版一致，老文件直接能读。
/// </summary>
public sealed class ConfigService
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        // 宽松编码器：中文设备名和中文路径按原样写出去，与 Go 版产物一致，
        // 别把界面要读的值变成一串 \uXXXX。
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly object _gate = new();
    private readonly string _filePath;
    private PickerConfig _config = new();

    public ConfigService() : this(ConfigDir()) { }

    /// <summary>测试用：直接指定配置目录。</summary>
    public ConfigService(string dir)
    {
        Directory.CreateDirectory(dir);
        _filePath = Path.Combine(dir, "devices.json");
        Load();
    }

    /// <summary>配置目录：SCRCPY_CONFIG_DIR 优先，其次 %APPDATA%，拿不到就退回临时目录。</summary>
    public static string ConfigDir()
    {
        string? fromEnv = Environment.GetEnvironmentVariable("SCRCPY_CONFIG_DIR");
        if (!string.IsNullOrWhiteSpace(fromEnv)) return fromEnv;

        string baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
        return Path.Combine(baseDir, "ScrcpyPicker");
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return;
            var loaded = JsonSerializer.Deserialize<PickerConfig>(File.ReadAllText(_filePath));
            if (loaded is null) return;
            _config = loaded with
            {
                Devices = loaded.Devices ?? new Dictionary<string, DeviceCache>(),
                Settings = loaded.Settings ?? new PickerSettings(),
            };
        }
        catch
        {
            // 文件坏了就当空的用；下一次写入会把它覆盖成合法 JSON。
        }
    }

    /// <summary>返回配置副本（devices 是新字典），调用方不用担心并发改动。</summary>
    public PickerConfig Snapshot()
    {
        lock (_gate)
        {
            return _config with { Devices = new Dictionary<string, DeviceCache>(_config.Devices) };
        }
    }

    public bool TryGetDevice(string key, out DeviceCache cache)
    {
        lock (_gate)
        {
            if (_config.Devices.TryGetValue(key, out var found))
            {
                cache = found;
                return true;
            }
        }
        cache = new DeviceCache();
        return false;
    }

    /// <summary>读不到时返回空条目（对应 Go 返回零值的用法），调用方按字段是否为空判断。</summary>
    public DeviceCache Device(string key)
    {
        lock (_gate) return _config.Devices.TryGetValue(key, out var c) ? c : new DeviceCache();
    }

    public void SetDevice(string key, DeviceCache value)
    {
        PickerConfig toWrite;
        lock (_gate)
        {
            _config.Devices[key] = value;
            toWrite = CloneLocked();
        }
        Save(toWrite);
    }

    public void RemoveDevice(string key)
    {
        PickerConfig toWrite;
        lock (_gate)
        {
            _config.Devices.Remove(key);
            toWrite = CloneLocked();
        }
        Save(toWrite);
    }

    public PickerSettings Settings()
    {
        lock (_gate) return _config.Settings;
    }

    /// <summary>覆盖整份设置并落盘。</summary>
    public void SetSettings(PickerSettings settings)
    {
        PickerConfig toWrite;
        lock (_gate)
        {
            _config = _config with { Settings = settings };
            toWrite = CloneLocked();
        }
        Save(toWrite);
    }

    public void SetPreferUsb(bool value) => SetSettings(Settings() with { PreferUsb = value });

    /// <summary>导航条开关（老文件没写过这个键时按开处理）。</summary>
    public bool NavBar()
    {
        lock (_gate) return _config.Settings.NavBar;
    }

    public void SetNavBar(bool value) => SetSettings(Settings() with { NavBar = value });

    /// <summary>记住的工具目录，空串表示没记过。</summary>
    public string ToolDir()
    {
        lock (_gate) return _config.Settings.ToolDir;
    }

    /// <summary>记住 adb / scrcpy 目录；传空串表示清除（回到纯自动查找）。</summary>
    public void SetToolDir(string dir) => SetSettings(Settings() with { ToolDir = dir });

    /// <summary>配置文件完整路径（诊断展示用）。</summary>
    public string FilePath => _filePath;

    /// <summary>调用方必须已持有 _gate；records 不可变，浅拷字典即可自洽。</summary>
    private PickerConfig CloneLocked() =>
        _config with { Devices = new Dictionary<string, DeviceCache>(_config.Devices) };

    private void Save(PickerConfig cfg)
    {
        string json;
        try
        {
            json = JsonSerializer.Serialize(cfg, WriteOptions);
        }
        catch
        {
            return;
        }

        // 先写临时文件再覆盖：进程中途被杀不会留下半个 devices.json。
        string tmp = _filePath + ".tmp";
        try
        {
            File.WriteAllText(tmp, json);
            File.Move(tmp, _filePath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* 忽略 */ }
        }
    }
}
