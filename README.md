# Індекс ШІ-зрілості організаційної культури

Анонімне опитування культурної готовності компаній до системного використання
штучного інтелекту. Відповіді колег зводяться в індекс організації за унікальним
кодом організації — так само, як у AI Readiness Diagnostic від AInoia.

**Код організації.** Першому респонденту (координатору) сторінка генерує код
(8 символів, `A–Z`/`2–9` без `0/O/1/I`) і наприкінці показує посилання
`?org=КОД&from=Імʼя` для колег. Колеги, що перейшли за посиланням, отримують
код автоматично; у базі `company_key = lower(org_code)`, тому індекс організації
рахується саме за кодом, а не за написанням назви. `?reset` очищає чернетку в
браузері; кнопка «Розпочати нову анкету» дає координатору новий код.
База, розгорнута до появи коду, переводиться скриптом `db/migrate-2026-09-07-org-code.sql`.

**Стек (продакшн):** статична сторінка на GitHub Pages → Neon Data API (керований PostgREST) → PostgreSQL у Neon.
Альтернатива для власного сервера: PostgREST + PostgreSQL у Docker (розділ «Свій сервер»).

---

## Що всередині

| Шлях | Призначення |
|---|---|
| `index.html` | Уся анкета: 51 питання, 10 кроків, розрахунок індексів і достовірності оцінки у браузері. Самодостатній файл — стилі й логіка вбудовані. |
| `assets/plato-hero.png` | Hero-зображення з дизайн-системи AInoia. |
| `db/schema.sql` | Таблиці, RLS-політики, представлення для аналітики. |
| `db/neon-grants.sql` | Insert-only права ролі `anonymous` для Neon Data API. Застосовувати після увімкнення Data API. |
| `.github/workflows/pages.yml` | Публікація лише статики (`index.html` + `assets/`) на GitHub Pages при push у `main`. |
| `db/pgvector.sql` | Необов'язкове: ембединги відкритих відповідей для семантичного аналізу. |
| `deploy/docker-compose.yml` | Альтернатива: Postgres + PostgREST на власному сервері, опційно Caddy (TLS) і Metabase. |
| `deploy/01-roles.sh` | Створення ролей `web_anon` та `authenticator` при першому старті. |
| `deploy/Caddyfile` | Зворотний проксі з автоматичним сертифікатом Let's Encrypt. |
| `deploy/apps-script/Code.gs` | Резервний збір у Google Sheets; у продакшні вимкнено (`SHEETS_URL = ""`). |

---

## Розгортання (продакшн: GitHub Pages + Neon)

Та сама схема, що й у AI Readiness Diagnostic AInoia: сторінка на Pages, база й API у Neon.
Свій PostgREST не потрібен — Neon Data API є керованим PostgREST поверх тієї самої бази.

| Шар | Де |
|---|---|
| Код | `github.com/AlStanK/ai-maturity-survey`, `main` = канон |
| Сторінка | `https://alstank.github.io/ai-maturity-survey/`, публікує `.github/workflows/pages.yml` |
| База | Neon, проєкт AInoia (`eu-central-1`), база `survey`, схема `public` |
| API | `https://ep-orange-flower-b29e9zvj.apirest.c-6.eu-central-1.aws.neon.tech/survey/rest/v1`, анонімні запити → роль `anonymous` |
| Auth | `https://ep-orange-flower-b29e9zvj.neonauth.c-6.eu-central-1.aws.neon.tech/poll/auth` — сторінка бере анонімний JWT перед POST. Neon Auth один на гілку і привʼязаний до бази `poll`; його токен приймає Data API обох баз |

Рядок підключення власника — `neonctl connection-string --database-name survey --role-name neondb_owner`
(див. `~/.claude/secrets-registry.md`, у git не потрапляє).

### 1. База

```bash
neonctl databases create --project-id <project> --name survey --owner-name neondb_owner
SURVEY_URL=$(neonctl connection-string --project-id <project> --database-name survey --role-name neondb_owner)
psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
```

### 2. Data API

```bash
neonctl data-api create --project-id <project> --database survey --auth-provider neon_auth \
  --db-schemas public --db-anon-role anonymous --openapi-mode disabled \
  --server-cors-allowed-origins https://alstank.github.io
psql "$SURVEY_URL" -v ON_ERROR_STOP=1 -f db/neon-grants.sql
```

Neon Data API не приймає запити без JWT, навіть анонімні: сторінка спершу робить
`GET AUTH_URL/token/anonymous` і кладе токен в `Authorization: Bearer`. Окремий Neon Auth
для `survey` увімкнути не можна (один на гілку, уже зайнятий базою `poll`), тому
`AUTH_URL` вказує на `/poll/auth` — токен ролі `anonymous` Data API `survey` приймає.

Перевірено на живому API (2026-09-07): `POST /responses` → 201, `POST /report_subscribers` → 201,
`GET /responses` і `GET /v_company_summary` анонімом → відмова, preflight з чужого домену — без CORS.

### 3. Сторінка

У `index.html`, у блоці конфігурації на початку скрипта, `API_URL` і `AUTH_URL` вказують на Neon.
`SHEETS_URL` порожній: Google Sheets лишається резервним каналом, не основним.

Pages публікується через GitHub Actions (Settings → Pages → Source: **GitHub Actions**).
У продакшн потрапляють лише `index.html` і `assets/`.

### 4. Аналітика

Читати дані — тільки власником через `psql "$SURVEY_URL"` або Metabase, підключений до Neon
тим самим рядком. Починати з `v_company_summary`, `v_industry_benchmark`, `v_perception_gap`.

---

## Свій сервер (альтернатива Neon)

### Що потрібно

* сервер із Docker і публічною IP-адресою;
* домен для API (наприклад `api.example.com`) з A-записом на цей сервер;
* відкриті порти 80 і 443.

Домен і TLS — не забаганка. Сторінка живе на `https://`, тому браузер
заблокує звернення до `http://` API як змішаний вміст. API мусить бути
під сертифікатом.

### 1. Підняти стек

```bash
cd deploy
cp .env.example .env      # заповнити паролі: openssl rand -base64 24
docker compose --profile tls up -d
```

При першому старті порожнього тому Postgres сам виконає, у такому порядку:

1. `01-roles.sh` — ролі `web_anon` (анонімний відвідувач) і `authenticator`
   (під нею підключається PostgREST);
2. `db/schema.sql` — таблиці, політики, представлення;
3. `db/pgvector.sql` — розширення для семантичного аналізу.

Порт Postgres назовні не публікується: до бази ходять лише сусідні контейнери.

### 2. Підключити сторінку

У `index.html`, у блоці конфігурації на початку скрипта:

```js
const API_URL = "https://api.example.com";
const AUTH_URL = "";  // токен не потрібен: анонімна роль задана в PostgREST
const API_KEY = "";   // для власного PostgREST не потрібен
```

`API_KEY` існує лише для випадку, коли перед PostgREST стоїть шлюз із ключем.
У власній інсталяції доступ обмежують гранти й політики RLS у самій базі,
тому ключа немає й підробляти нічого.

Поки `API_URL` порожній, сторінка працює в локальному режимі: відповіді
лишаються в браузері респондента, індекси рахуються на пристрої, є кнопка
вивантаження JSON.

### 3. Дозволити домен сторінки

У `deploy/.env`:

```
CORS_ORIGINS=https://alstank.github.io
```

Через кому, без пробілів. PostgREST віддасть заголовки CORS лише переліченим
доменам — звернення з чужого сайту браузер відхилить.

### 4. Опублікувати сторінку

Так само, як у продакшн-схемі: workflow `.github/workflows/pages.yml` при push у `main`.

Сторінка стане доступною за адресою `https://<user>.github.io/ai-maturity-survey/`.

### 5. Metabase

```bash
docker compose --profile bi up -d
```

Підключити базу як Postgres: host `db`, порт 5432, користувач і пароль
власника з `.env`. Metabase заходить під власником, тому бачить і таблиці,
і представлення.

Починати варто з `v_company_summary` та `v_industry_benchmark` — обидва вже
враховують поріг анонімності.

`v_perception_gap` показує розрив у сприйнятті між керівниками й виконавцями
однієї компанії: додатний `avg_gap` означає, що керівництво оцінює стан вище
за команду. Показується лише за наявності щонайменше 2 керівників і 3
виконавців.

---

## Модель доступу

| Роль | Права |
|---|---|
| `web_anon` (PostgREST) / `anonymous` (Neon) | Тільки `INSERT` у `responses` і `report_subscribers` |
| `authenticator` | Лише вхід і перемикання на `web_anon`, власних прав не має |
| власник бази | Повний доступ; під ним працює Metabase і скрипт ембедингів |

Для `web_anon` немає жодної політики `SELECT`, `UPDATE` чи `DELETE`.
Права на представлення відкликані окремо: представлення в Postgres
виконуються з правами власника й інакше обходили б RLS.

Схема написана незалежно від імені анонімної ролі — вона працює і з
`web_anon` (PostgREST), і з `anon` (Supabase), створюючи політики для тієї
ролі, яка реально існує в базі.

**Перевірено на піднятому стеку:**

| Запит | Результат |
|---|---|
| `POST /responses` | `201` |
| `POST /report_subscribers` | `201` |
| `GET /responses` | `401` |
| `GET /v_company_summary` | `401` |
| `GET /answer_embeddings` | `401` |
| `DELETE /responses` | `401` |
| `OPTIONS` з дозволеного домену | заголовки CORS видано |
| `OPTIONS` з чужого домену | заголовків немає |

Наскрізний прогін анкети з браузера: відповідь дійшла до Postgres, усі поля
розклалися по колонках, email опинився в окремій таблиці й **не потрапив**
у `answers`.

---

## Семантичний аналіз відкритих відповідей

Питання 44 і 45 — вільний текст. `db/pgvector.sql` створює:

* `answer_embeddings` — вектори відповідей, індекс HNSW за косинусною відстанню;
* `similar_answers(embedding, field, limit)` — пошук близьких за змістом висловлювань;
* `v_pending_embeddings` — черга ще не оброблених відповідей.

Розмірність `vector(1536)` розрахована на `text-embedding-3-small`. Інша
модель — інша розмірність: типи `vector(n)` між собою несумісні.

Ембединги рахує окремий скрипт під власником бази. **З браузера це робити
не можна:** ключ моделі опинився б у коді сторінки.

> **Питання етики.** Відправка відкритих відповідей у зовнішній API ембедингів —
> це передача дослідницьких даних третій стороні. Перед цим варто або отримати
> згоду в тексті анкети, або рахувати ембединги локальною моделлю.

---

## Етика

* Ім'я, посада, IP-адреса респондента не збираються.
* Назва компанії потрібна для агрегації в межах організації; індивідуальні
  відповіді роботодавцю не передаються.
* Компанійний звіт формується лише за наявності **≥ 5 анкет**; поріг вбудований
  у представлення, а не тільки в регламент.
* Email для розсилки звіту зберігається в окремій таблиці й не потрапляє
  в `answers`.
* Компанії між собою не порівнюються й не ранжуються.

---

## Розрахунки

Зворотні пункти (`ps3`, `ps5`, `ps7`, `gv4`) інвертуються за формулою `6 − бал`.

| Індекс | Пункти |
|---|---|
| Психологічна безпека | `ps1`–`ps7`, адаптована шкала А. Едмондсон (1999) |
| Лідерство та правила | `gv1`–`gv8` |
| Сприйнята ефективність | `ef1`–`ef4`: операційний, управлінський, адаптивний вимір і якість |

Розрив по процесу = «потрібно» − «зараз». Відповіді «Н/З» виключаються
із середніх, а не рахуються нулем.

---

## Резервні копії

```bash
docker compose exec db pg_dump -U postgres aimaturity | gzip > backup-$(date +%F).sql.gz
```

Дані існують в одному екземплярі й не відновлюються повторним
опитуванням. Копію варто робити щодня, поки триває збір.

---

## Ліцензія

Питання та методику можна використовувати з посиланням
на автора роботи.
