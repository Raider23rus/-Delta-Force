# -Delta-Force Helper

RecoilControl\
├── Start-Recoil.ps1              # точка входа
├── Modules\
│   ├── RecoilCore.psm1           # C#-ядро (SendInput, GetAsyncKeyState, поток)
│   ├── RecoilConfig.psm1         # status.txt + профили
│   ├── RecoilWebUI.psm1          # HttpListener + REST API
│   └── RecoilBootstrap.psm1      # связка старт/стоп
└── Web\
    └── index.html                # HTML+CSS+JS одной страницей
