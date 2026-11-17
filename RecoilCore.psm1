<#
.SYNOPSIS
    Ядро компенсации отдачи: C#-тип + управление фоновым потоком.
.DESCRIPTION
    Содержит:
      - Get-RecoilSource     : возвращает строку с C#-кодом (для Add-Type)
      - Initialize-RecoilCore: компилирует C#-тип один раз за сессию
      - Start-RecoilThread   : запускает RunControl() в фоновом потоке
      - Stop-RecoilThread    : сигналит isActive=false и ждёт завершения
.NOTES
    C#-код НЕ пишет в консоль — только в status.txt.
    Это критично: два "художника" (C# и PowerShell) затирали бы меню.
#>

# Кэш скомпилированного типа. Add-Type нельзя вызывать дважды с тем же именем
# в одном AppDomain — иначе ошибка "type already exists".
$script:RecoilType = $null

function Get-RecoilSource {
    <#
    .SYNOPSIS
        Возвращает C#-исходник для Add-Type.
    .DESCRIPTION
        Использует only-ASCII строки внутри C# (никаких ╔══╗), чтобы
        кодировка .psm1-файла не влияла на компиляцию.
    #>
    return @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class AdvancedRecoilControl
{
    // ---------- Win32 P/Invoke ----------
    // GetAsyncKeyState: старший бит = "клавиша нажата сейчас".
    // ВАЖНО: не видит ввод, эмулированный SendInput из другого процесса.
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    // MOUSEINPUT/INPUT — структуры для SendInput (документировано в Win32 API).
    // mouse_event устарел и в некоторых средах не работает.
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const uint INPUT_MOUSE      = 0;
    private const uint MOUSEEVENTF_MOVE = 0x0001; // относительное движение

    // ---------- Состояние ----------
    private static readonly Random rand = new Random();

    // volatile: флаги читаются/пишутся из разных потоков без блокировок.
    private static volatile bool isActive  = true;
    private static volatile bool isPaused  = false;

    // heldKeys: для edge-trigger. Хранит клавиши, которые уже были "нажаты"
    // в предыдущем кадре — чтобы Numpad/F-клавиши не срабатывали каждый кадр.
    private static readonly HashSet<int> heldKeys = new HashSet<int>();

    // Пути: Documents\RecoilProfiles — общие для C#, PowerShell и Web UI.
    private static readonly string configDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "RecoilProfiles");
    private static readonly string statusFile = Path.Combine(configDir, "status.txt");
    private static string currentProfile = "default";

    // Настройки. Дефолт 1.5/0.0/50 — "нейтральный" старт.
    private static double verticalRecoil   = 1.5;
    private static double horizontalRecoil = 0.0;
    private static int    speed            = 50;   // 1..100, 50 = normal

    // lastStatusWrite: чтобы не перечитывать status.txt каждый кадр.
    // Сравниваем LastWriteTimeUtc — если не менялся, пропускаем парсинг.
    private static DateTime lastStatusWrite = DateTime.MinValue;

    // Публичный "стоп" — вызывается из PowerShell при завершении.
    public static void StopControl() { isActive = false; }

    // ---------- Утилиты ввода ----------
    private static bool KeyDown(int vKey)
    {
        return (GetAsyncKeyState(vKey) & 0x8000) != 0;
    }

    // Edge-trigger: true только в первом кадре после нажатия.
    // Так Numpad1 не "прокручивает" значение 60 раз/сек, пока зажата.
    private static bool KeyPressed(int vKey)
    {
        bool down = KeyDown(vKey);
        if (down)
        {
            if (heldKeys.Contains(vKey)) return false;
            heldKeys.Add(vKey);
            return true;
        }
        heldKeys.Remove(vKey);
        return false;
    }

    // Относительное движение мыши. dx/dy — пиксели; знак: +y вниз (экранные координаты).
    private static void MoveMouse(int dx, int dy)
    {
        INPUT[] inputs = new INPUT[1];
        inputs[0].type           = INPUT_MOUSE;
        inputs[0].mi.dx          = dx;
        inputs[0].mi.dy          = dy;
        inputs[0].mi.mouseData   = 0;
        inputs[0].mi.dwFlags     = MOUSEEVENTF_MOVE;
        inputs[0].mi.time        = 0;
        inputs[0].mi.dwExtraInfo = IntPtr.Zero;
        SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // ---------- Файл состояния ----------
    // Атомарная запись: пишем во .tmp, затем Move поверх. Иначе Web UI
    // может прочитать половину файла в момент перезаписи.
    private static void WriteStatusFile()
    {
        try
        {
            Directory.CreateDirectory(configDir);
            string content =
                "PROFILE="    + currentProfile + Environment.NewLine +
                "VERTICAL="   + verticalRecoil.ToString("0.00", CultureInfo.InvariantCulture) + Environment.NewLine +
                "HORIZONTAL=" + horizontalRecoil.ToString("0.00", CultureInfo.InvariantCulture) + Environment.NewLine +
                "SPEED="      + speed.ToString(CultureInfo.InvariantCulture) + Environment.NewLine +
                "PAUSED="     + (isPaused ? "1" : "0") + Environment.NewLine;

            string tmp = statusFile + ".tmp";
            File.WriteAllText(tmp, content);
            if (File.Exists(statusFile)) File.Delete(statusFile);
            File.Move(tmp, statusFile);

            lastStatusWrite = File.GetLastWriteTimeUtc(statusFile);
        }
        catch { /* не критично: если не удалось записать — работаем со старым */ }
    }

    // Подхватываем изменения, сделанные Web UI.
    // Парсим только если mtime изменился — иначе горячий цикл будет
    // читать файл 100 раз/сек впустую.
    private static void ReloadFromStatusIfChanged()
    {
        try
        {
            if (!File.Exists(statusFile)) return;
            DateTime mt = File.GetLastWriteTimeUtc(statusFile);
            if (mt == lastStatusWrite) return;

            string[] lines = File.ReadAllLines(statusFile);
            foreach (string line in lines)
            {
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string key = line.Substring(0, eq);
                string val = line.Substring(eq + 1);

                switch (key)
                {
                    case "PROFILE":
                        // Смена профиля из веба: подгружаем .cfg.
                        if (!string.IsNullOrEmpty(val) && val != currentProfile)
                        {
                            string p = Path.Combine(configDir, val + ".cfg");
                            if (File.Exists(p))
                            {
                                string[] cfg = File.ReadAllLines(p);
                                if (cfg.Length >= 2)
                                {
                                    verticalRecoil   = double.Parse(cfg[0], CultureInfo.InvariantCulture);
                                    horizontalRecoil = double.Parse(cfg[1], CultureInfo.InvariantCulture);
                                }
                                if (cfg.Length >= 3)
                                {
                                    int sp; if (int.TryParse(cfg[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out sp))
                                        speed = Math.Max(1, Math.Min(100, sp));
                                }
                            }
                            currentProfile = val;
                        }
                        break;
                    case "VERTICAL":
                        // InvariantCulture: иначе на русской локали "1.5" не распарсится.
                        double v; if (double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) verticalRecoil = v;
                        break;
                    case "HORIZONTAL":
                        double h; if (double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out h)) horizontalRecoil = h;
                        break;
                    case "SPEED":
                        int s; if (int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out s)) speed = Math.Max(1, Math.Min(100, s));
                        break;
                    case "PAUSED":
                        isPaused = (val == "1");
                        break;
                }
            }
            lastStatusWrite = mt;
        }
        catch { /* битый файл — игнорируем, продолжим со старыми значениями */ }
    }

    // ---------- Профили ----------
    private static void EnsureDefaultProfile()
    {
        Directory.CreateDirectory(configDir);
        string path = Path.Combine(configDir, "default.cfg");
        if (!File.Exists(path)) SaveConfig("default");
    }

    private static void LoadConfig(string profileName)
    {
        string filePath = Path.Combine(configDir, profileName + ".cfg");
        if (!File.Exists(filePath)) return;
        try
        {
            string[] lines = File.ReadAllLines(filePath);
            if (lines.Length >= 2)
            {
                verticalRecoil   = double.Parse(lines[0], CultureInfo.InvariantCulture);
                horizontalRecoil = double.Parse(lines[1], CultureInfo.InvariantCulture);
                if (lines.Length >= 3)
                {
                    int sp; if (int.TryParse(lines[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out sp))
                        speed = Math.Max(1, Math.Min(100, sp));
                }
                currentProfile = profileName;
            }
        }
        catch { }
    }

    // Формат .cfg: 3 строки (V, H, speed). Старые 2-строчные тоже читаются.
    private static void SaveConfig(string profileName)
    {
        Directory.CreateDirectory(configDir);
        File.WriteAllText(
            Path.Combine(configDir, profileName + ".cfg"),
            verticalRecoil.ToString("0.00", CultureInfo.InvariantCulture) + Environment.NewLine +
            horizontalRecoil.ToString("0.00", CultureInfo.InvariantCulture) + Environment.NewLine +
            speed.ToString(CultureInfo.InvariantCulture) + Environment.NewLine);
        currentProfile = profileName;
    }

    // ---------- Главный цикл ----------
    public static void RunControl()
    {
        EnsureDefaultProfile();
        LoadConfig("default");
        WriteStatusFile();

        // VK-коды: см. https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes
        const int VK_LBUTTON = 0x01; // левая кнопка мыши
        const int VK_F7      = 0x76; // Pause/Resume
        const int VK_F12     = 0x7B; // Exit

        while (isActive)
        {
            // 1) Подхватить изменения из Web UI (если файл менялся).
            ReloadFromStatusIfChanged();

            // 2) Аварийные хоткеи (edge-trigger, чтобы не спамили).
            if (KeyPressed(VK_F12)) break;
            if (KeyPressed(VK_F7)) { isPaused = !isPaused; WriteStatusFile(); }
            if (isPaused) { Thread.Sleep(50); continue; }

            // 3) Компенсация: только пока зажата ЛКМ.
            if (KeyDown(VK_LBUTTON))
            {
                // Небольшой рандом: ±10% по V, ±0.5 px по H.
                // Цель — не идеально ровная линия, а "человеческий" паттерн.
                double v = verticalRecoil   * (0.9 + rand.NextDouble() * 0.2);
                double h = horizontalRecoil + (rand.NextDouble() - 0.5);
                MoveMouse((int)Math.Round(h), (int)Math.Round(v));

                // speed=100 → в 2 раза быстрее (7-15 мс), speed=1 → очень медленно.
                // Math.Max(1, ...) защищает от Sleep(0)/отрицательного значения.
                int baseDelay = rand.Next(15, 31);
                int delay = (int)Math.Round(baseDelay * (100.0 / Math.Max(1, speed)));
                Thread.Sleep(Math.Max(1, delay));
            }

            // 4) Пауза кадра, чтобы не жечь CPU на 100%.
            Thread.Sleep(10);
        }

        isActive = false;
        WriteStatusFile();
    }
}
'@
}

function Initialize-RecoilCore {
    <#
    .SYNOPSIS
        Компилирует C#-тип один раз за сессию.
    .DESCRIPTION
        Повторный вызов — no-op, потому что Add-Type с тем же именем
        типа в одном AppDomain бросает исключение.
    #>
    [CmdletBinding()]
    param()

    if ($script:RecoilType -ne $null) { return }

    $src = Get-RecoilSource
    Add-Type -TypeDefinition $src -Language CSharp
    $script:RecoilType = [AdvancedRecoilControl]
}

function Start-RecoilThread {
    <#
    .SYNOPSIS
        Запускает RunControl() в фоновом потоке.
    .OUTPUTS
        System.Threading.Thread — им можно управлять снаружи (Join, Abort).
    #>
    [CmdletBinding()]
    param()

    Initialize-RecoilCore

    # CreateDelegate: получаем ThreadStart-делегат на статический метод RunControl.
    # IsBackground = true: поток не помешает PowerShell-процессу завершиться.
    $threadStart  = [Threading.ThreadStart]::CreateDelegate([Threading.ThreadStart], [AdvancedRecoilControl], "RunControl")
    $thread       = New-Object System.Threading.Thread($threadStart)
    $thread.IsBackground = $true
    $thread.Start()
    return $thread
}

function Stop-RecoilThread {
    <#
    .SYNOPSIS
        Сигналит isActive=false и ждёт до 2 секунд.
    .NOTES
        Даже если поток не успел завершиться, вызывающая сторона продолжит работу.
    #>
    [CmdletBinding()]
    param([System.Threading.Thread]$Thread)

    try { [AdvancedRecoilControl]::StopControl() } catch { }
    if ($Thread -ne $null) {
        try { [void]$Thread.Join(2000) } catch { }
    }
}

Export-ModuleMember -Function Initialize-RecoilCore, Start-RecoilThread, Stop-RecoilThread
