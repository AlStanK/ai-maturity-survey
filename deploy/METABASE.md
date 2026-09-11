# Metabase для дослідження «Індекс ШІ-зрілості»

Інструкція з налаштування Metabase BI для візуалізації результатів дослідження та вбудовування дашборду у веб-сторінку `analytics.html`.

---

## 1. Запуск Metabase

Metabase запускається в окремому легкому Docker-контейнері з портом `3030` та постійним томом для даних:

```bash
cd deploy
docker compose -f docker-compose.metabase.yml up -d
```

Перевірити статус:
```bash
docker compose -f docker-compose.metabase.yml ps
```

Інтерфейс доступний за адресою: **[http://localhost:3030](http://localhost:3030)**.

---

## 2. Початкове налаштування (Wizard)

1. Відкрийте `http://localhost:3030`.
2. Оберіть мову та натисніть **Let's get started**.
3. Створіть обліковий запис адміністратора (ім'я, email, пароль).
4. На кроці підключення бази оберіть **PostgreSQL** (або натисніть *I'll add my data later* і додайте через Admin Settings).

---

## 3. Підключення бази Neon (`survey`)

У **Admin Settings -> Databases -> Add database**:
* **Database type:** `PostgreSQL`
* **Name:** `AI Maturity Survey`
* **Host:** хост вашого Neon проєкту (отримується командою нижче)
* **Port:** `5432`
* **Database name:** `survey`
* **Database username:** `neondb_owner`
* **Database password:** пароль власника з Neon
* **Use SSL:** `Yes` (Require)

> **Як отримати рядок підключення без збереження секретів:**
> ```bash
> npx neonctl connection-string --project-id fancy-shadow-07146949 --database-name survey --role-name neondb_owner
> ```

---

## 4. Готові SQL-представлення для візуалізації

У схемі `public` автоматично доступні аналітичні views:

1. **`v_company_summary`** — зведені індекси компаній:
   * `company_name`, `respondents_count`
   * `psychological_safety_idx` (1.0–5.0)
   * `governance_idx` (1.0–5.0)
   * `perceived_effectiveness_idx` (1.0–5.0)
   * `assessment_confidence` (0–100%)
2. **`v_perception_gap`** — розрив у сприйнятті між керівниками та виконавцями:
   * `company_name`, `role_group`
   * `avg_gap` (додатне значення = керівництво оцінює стан вище за команду)
3. **`v_industry_benchmark`** — середні показники за галузями.
4. **`v_process_gaps`** — розриви «потрібно» vs «зараз» по бізнес-процесах.

---

## 5. Створення та вбудовування дашборду

1. Створіть новий дашборд у Metabase (наприклад, **«Зрілість культури ШІ»**) та додайте графіки на основі вищевказаних таблиць.
2. Перейдіть у **Admin Settings -> Settings -> Embedding in other applications** та увімкніть тумблер **Enable Embedding**.
3. На самому дашборді натисніть значок **Sharing** (стрілка праворуч угорі) -> **Sharing and embedding**.
4. Оберіть **Public link** (або **Embed this dashboard in an application**) -> **Enable**.
5. Скопіюйте посилання виду:
   `http://localhost:3030/public/dashboard/c91a0...#bordered=false&titled=false`
6. Відкрийте сторінку `analytics.html`, натисніть **«Налаштувати джерело»** і вставте це посилання. Воно збережеться у вашому браузері.
