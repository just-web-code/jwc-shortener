# jwc-shortener A/B benchmark — so'rov loglashni kritik yo'ldan olib chiqish

> **Tarixiy yozuv.** Quyidagi o'lchovlar 0.9.x ning `jwc build --native`
> yo'lida olingan. Native backend 0.9.902 da qaytdi (`jwc build`), lekin bu
> raqamlar hali qayta o'lchanmagan — hozircha dastur `jwc serve`
> ostida interpretator bilan ishlaydi — va `log_insert` ham olib tashlangan
> (builtins.md §10): telemetriya qatorini `after` bloki oddiy `insert` bilan
> yozadi. Raqamlar o'sha paytda o'lchangan holicha qoldirilgan; ular
> bugungi ishlash ko'rsatkichi emas.

**Sana:** 2026-08-12
**Kompilyator:** o'rnatilgan `jwc 0.9.4` (`b636f62`) — ikkala tomon uchun ham
**Baseline:** jwc-shortener `5cd04b1` (merge oldidagi `main`)
**After:** jwc-shortener `54c5141` (`claude/redis-package-qoshish-f1of1e`)

## Xulosa

`api_call` INSERT'ini request fazasidan buffered writer'ga ko'chirish native AOT
buildda **12.9x throughput va 92% kamroq o'rtacha latency** beradi:
7 951 → 102 551 req/s, 6.28 ms → 482 µs. Uchala da'vo ham tasdiqlandi.

0.9.4 da **drop butunlay yo'qoldi**: 3.05M va 3.10M so'rovda `dropped=0`,
`failed=0`, qatorlarning 100% i yozildi. 0.9.2 da bu ko'rsatkich 46% edi.

Ikkala tomon bir xil kompilyator bilan qurilgan va A B A B tartibida ikki
marta yugurtirilgan, ya'ni yagona o'zgaruvchi — ilova kodi.

## Muhit va uslub

- Windows 11, 12 core, `x86_64-pc-windows-msvc`, rustc 1.97.1.
- Postgres 17.10, Docker (`jwc-bench-pg`, port 5434). **Har tomonga alohida
  baza** (`jwcbench_main`, `jwcbench_after`): branch migratsiyasi `latency_us`
  ni `NOT NULL` qilib qo'shadi, umumiy sxemada baseline INSERT'i yiqilardi.
- `JWC_REDIS_URL` o'rnatilmagan — `redis` paketi in-process cache'ga tushadi.
- Har yugurishdan oldin ilova noldan quriladi (`rm -rf .jwc-build bin`).
- Yuklama: `bombardier -c 50 -d 30s -l http://localhost:8080/`. Oldin 10s
  warm-up (tashlanadi), keyin `TRUNCATE`, oxirida 5s kutish.
- **Hisoblagichlar warm-up'dan keyin snapshot qilinadi va ayiriladi** — aks
  holda `written ÷ batches` warm-up oynasini o'lchovga aralashtiradi.
- Tartib: main → after → main → after (mashina/DB driftini yo'qotish uchun).

Majburiy chetlanish: Linux emas, Windows'da yurgizildi — bu mashinadagi WSL'da
tashqi tarmoq yo'q. Absolyut raqamlar deploydagi raqamlar emas, nisbatlar
to'g'ri.

## Native AOT natijalari

| Ko'rsatkich | main (baseline) | branch (after) | Farq |
|---|---|---|---|
| Req/s (2 raund o'rtachasi) | 7 950.62 | 102 550.73 | **+12.90x** |
| O'rtacha latency | 6.28 ms | 481.8 µs | −92.3% |
| p50 | 5.98 ms | 513 µs | −91.4% |
| p90 | 6.99 ms | 869 µs | −87.6% |
| p95 | 9.05 ms | 1.04 ms | −88.5% |
| p99 | 11.74 ms | 1.51 ms | −87.1% |
| Yozilgan qator | 100% | **100%** | — |
| `dropped` / `failed` | — | **0 / 0** | — |

Raundlar alohida:

| Raund | main req/s | after req/s | Nisbat | after: so'rov / qator |
|---|---|---|---|---|
| 1 | 7 848.21 | 101 623.02 | 12.95x | 3 048 360 / 3 048 360 |
| 2 | 8 053.03 | 103 478.44 | 12.85x | 3 103 175 / 3 103 175 |

Ikkala tomon ham barqaror (±1.3%). Max latency shovqinli: after r1 da 50.07 ms,
r2 da 22.90 ms, baseline'da 24.97 va 21.12 ms — ya'ni tail bo'yicha ishonchli
farq yo'q, p99 gacha esa farq izchil.

## Yozuvchi shifti — to'yintirish harnessi

Shortener so'rovga bitta qator loglaydi, 0.9.4 da yozuvchi bunga bemalol
ulguradi — shuning uchun uning **shifti ko'rinmaydi**. Shiftni o'lchash uchun
alohida harness yozildi: `/burst` route har so'rovda 20 qator loglaydi
(`C:\Users\nbkab\jb\bh`, hech qaysi repoda emas).

Bitta binar, konfiguratsiya faqat env bilan, A B A B tartibida, 20s:

| Konfiguratsiya | rows/s (r1) | rows/s (r2) | qator/batch | req/s |
|---|---|---|---|---|
| OLD (`BATCH=500`, `CONCURRENCY=1`) | 49 985 | 53 502 | 500 | ~88 200 |
| **NEW (default `2000` / `4`)** | **218 044** | **209 133** | 2 000 | ~75 600 |

**Shift 4.13x oshgan** (51.7k → 213.6k rows/s). `failed=0` hamma yugurishda.

Ikkita kuzatuv. Birinchisi: OLD ning shifti (~51.7k) mening 0.9.2 dagi native
shortener o'lchovim (~49.2k) bilan mos — briefdagi "46% = shift ÷ taklif"
tushuntirishi to'g'ri. Ikkinchisi: bu mashinada yutuq brief'dagi Linux
o'lchovidan **kattaroq** (4.13x vs 3.55x), ya'ni "Windows'da round-trip
qimmatroq, shuning uchun concurrency ko'proq yordam berishi kerak" degan taxmin
tasdiqlandi.

NEW da req/s pastroq (75.6k vs 88.2k) — yozuvchi CPU olyapti. Aynan shu sababdan
`written%` ni asosiy ko'rsatkich qilib bo'lmaydi: OLD 2.9%, NEW 14.1% ko'rsatadi,
lekin ikkalasi ham taklifga bog'liq, taklif esa konfiguratsiyaga qarab o'zgaradi.

## Build vaqti va binar hajmi

| | main | branch | Farq |
|---|---|---|---|
| `jwc build --native --release` | 109.1 s | 130.7 s | +21.6 s (+19.8%) |
| Binar hajmi | 4 576 256 B (4.36 MB) | 6 720 512 B (6.41 MB) | +2 144 256 B (+46.9%) |
| `reqwest` (`.jwc-build/Cargo.toml`) | yo'q | yo'q | — |

## Uchala da'vo

**1. Latency tushadi — TASDIQLANDI.** 6.28 ms → 482 µs, 7 951 → 102 551 req/s,
p99 gacha hamma persentil 87% dan ko'proq yaxshilandi, to'rtala yugurishda ham
takrorlandi. Sabab da'vodagidek: baseline route handler ishga tushishidan oldin,
request-faza middleware'ida sinxron INSERT qilardi.

Muhim shart: bu after-block haqiqatan ishlaydigan kompilyatorda to'g'ri. 0.9.0
da branch umuman loglamasdi (pastda).

**2. `latency_ms` doim 0 emas, `status` doim 200 emas — TASDIQLANDI.** 0.9.4 da
`response_duration_us()` va `latency_us` ustuni qo'shilgach, qiymat haqiqatan
ko'rinadi: 3.05M qatorda `latency_us` min 2, max 4 472, **o'rtacha 4.96 µs**.
`latency_ms` esa hamon 0 (min 0, max 4) — `GET /` millisekunddan tez, ya'ni
muammo o'lchovda emas, birlikda edi. `status` haqiqiy: `/nosuchcode` uchun
`status=404, latency_ms=4` yozilgani alohida tekshirilgan; bu yugurishda faqat
`GET /` yuklangani uchun hammasi 200.

**3. Native build `reqwest` ni kompilyatsiya qilmaydi — TASDIQLANDI, lekin bu til
o'zgarishi, ilova o'zgarishi emas.** Bitta kompilyator ikkala tomonni qurganda
`reqwest` **ikkala** generatsiya qilingan `Cargo.toml` da ham yo'q. Yutuq
jwc-lang'ning http-prelude ajratilishidan keladi va `http_get`/`fetch_json`
ishlatmaydigan har qanday dasturga tegishli — o'zgartirilmagan baseline'ga ham.
Binarni kichraytirmadi: `redis` paketi uning o'rnini ortig'i bilan egallaydi.

## Yo'l-yo'lakay topilgan narsalar

**1. Native codegen: `after { }` bloki ishlamas edi (0.9.2 da tuzatilgan).**
Branchning 0.9.0 dagi birinchi native yugurishi 117 791 req/s ko'rsatdi va
**0 qator** yozdi. Route tanasidagi `return` haqiqiy Rust `return` ga tushib,
`route_N_inner` dan butunlay chiqib ketardi — status yozish ham, after-zanjir
ham sakrab o'tilardi. Bu ilovadagi har bir route `return` bilan tugaydi, shuning
uchun qator soni "kam" emas, aniq nol edi. Interpretator har doim to'g'ri
ishlagan; 0.9.4 da tana alohida `async fn route_N_body()` ga chiqariladi.

**2. 0.9.0 da baseline o'z kompilyatori bilan umuman qurilmasdi** — `E021`,
`collect_jwc_files` vendor qilingan `qr-lite/` ga kirib, uni ikkinchi marta
`<root>` ga yuklardi. `dd80140` tuzatgan.

**3. Baseline'ning ishdan chiqish stsenariysi (tasodifan ko'rindi).** Postgres
konteyneri yugurishlar orasida to'xtab qolganda baseline **hech narsa** xizmat
qilmadi: 150 so'rovning hammasi 10s timeout bo'ldi, chunki sinxron INSERT
handler'dan oldin turadi. Telemetriya qatorini yo'qotish — so'rovni
yo'qotishdan yaxshiroq.

**4. Briefdagi bitta arifmetik xato.** "180 361 / 583 = 309 qator/batch" ikki xil
oynadan olingan: 180 361 — truncate'dan keyingi qator, 583 — warm-up bilan
jamlangan batch soni. Bir xil oynada 251 418 / 583 = **431**. Xulosa (flushlar
taymer bilan, to'lmasdan ketgan) o'zgarmaydi. Shu sababdan bu o'lchovda
hisoblagichlar warm-up'dan keyin snapshot qilinadi.

## O'lchanmagan narsalar

- Linux / musl / Docker raqamlari — WSL'da tarmoq yo'q, hammasi
  `x86_64-pc-windows-msvc`.
- Redis bilan rate-limiter — brief bo'yicha `JWC_REDIS_URL` o'rnatilmagan.
- `POST /api/links` — brief bo'yicha chiqarib tashlangan (rate-limited).
- `JWC_LOG_CONCURRENCY` ning oralig'i — faqat 1 va default 4 o'lchandi, 2/8
  o'lchanmadi.
- Shortener'da yozuvchining shifti — bu ilova unga yetib bormaydi; shift faqat
  alohida harnessda o'lchandi.

## Artefaktlar

`C:\Users\nbkab\AppData\Local\Temp\claude\c--Users-nbkab-OneDrive-Ishchi-stol-jwc-shortener\9f6b6752-6358-408e-aaa0-d34bd8ab6cfb\scratchpad\bench\`
— `results-r1-*`, `results-r2-*` (ilova A/B), `results-harness-*` (shift),
`run_side.sh`, `run_harness.sh`. Harness manbasi: `C:\Users\nbkab\jb\bh`.
