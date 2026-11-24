# iOS-апка «Світло»

SwiftUI-апка й віджети для того самого монітора Deye. Дані бере з Cloudflare-воркера (`GET /api/data`)
з ключем `APP_TOKEN`.

- Апка: стан світла (відколи, наживо), кільце батареї, анімовані потоки енергії, плитки тижня,
  «сьогодні», графіки заряду й споживання (Swift Charts), теплова карта, години по днях, відключення,
  батарея/мережа/аварії. Оновлення кожні 30 с і pull-to-refresh.
- Віджети: малий і середній на головному екрані; круглий, прямокутний і рядок на екрані блокування.

## Збирання

1. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` і впиши адресу воркера та `APP_TOKEN`
   (той самий, що `npx wrangler secret put APP_TOKEN`). Файл у `.gitignore`.
2. Відкрий `DeyeMonitor.xcodeproj` у Xcode.
3. Симулятор: просто ▶︎ Run.
4. Свій iPhone: Xcode → Settings → Accounts → додай Apple ID. Потім у цілях **DeyeMonitor** і **DeyeWidgets**
   → Signing & Capabilities → Team = твій (Personal Team). Підключи iPhone, увімкни на ньому
   Settings → Privacy & Security → Developer Mode, вибери телефон у Xcode і ▶︎ Run.
   З безкоштовним Apple ID апка працює 7 днів — потім просто ще раз ▶︎ Run.
