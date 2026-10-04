# RISE: the four things only you can do

2026-10-04 · Neil

Four tasks, about 35 minutes total. Everything else from the review is already done, deployed and verified. These four are left because they need an account only you can sign into, or a password only you have.

## Before you start

Do them in this order. Task 1 protects your money and takes two minutes, so it goes first even though it is the least interesting. Task 4 is the one that cannot be undone later, so do not stop before it.

| # | Task | Where | Time | If you skip it |
| --- | --- | --- | --- | --- |
| 1 | Spend limit | Anthropic Console | 2 min | A bad day costs real money with no ceiling |
| 2 | Run migration 005 | Supabase SQL Editor | 5 min | A stranger can call your signup function |
| 3 | Password rules | Supabase Auth | 3 min | Weak passwords stay allowed; the breach check needs Pro |
| 4 | Take a backup | Terminal | 15 min | One bad click deletes everything, permanently |

Have these open: the [Anthropic Console](https://console.anthropic.com), your [Supabase project](https://supabase.com/dashboard/project/okpqytfeyjkbxgjrbaen), and a Terminal window in the project folder.

### One rule, and it matters more than any of the four

**Never paste a command that came from a web page, a popup, or anything claiming to check whether you are a robot.** Not even if it looks official. On 19 September a page on your own site did exactly that, and the only reason nothing happened is that you did not run it.

Commands in this document are safe to run. Commands a website hands you are not. If a site ever asks you to open Terminal, close the tab.

## Task 1: put a ceiling on the Anthropic bill

**Two minutes. Do this one first.**

Your proxy now counts spending in shared storage, so the daily budget is real rather than per data centre. But every guard in that code depends on the code being correct. This one does not. It is enforced on Anthropic's side, so it holds even if something in RISE is wrong.

That matters more than usual right now, because you have auto-reload pointed at a card. Without a monthly limit, auto-reload will keep topping up for as long as something keeps spending.

### Steps

1. Go to [console.anthropic.com](https://console.anthropic.com) and sign in.
2. Open **Plans & Billing** in the left sidebar.
3. Find the **spend limit** or **usage limit** setting for the month.
4. Set it to a number you would genuinely be willing to lose if the worst happened. **I would suggest $25 to start.**
5. Save.
6. While you are on that screen, check your **auto-reload** amounts. Small is better: reload **$20** when the balance drops below **$5**. A large reload amount only makes a surprise larger.

### Why $25

A deep search costs about 60 cents, and the cohort cache means one paid run serves every student in that town for a day. So $25 a month is roughly 40 fresh searches a day, which is far more than you will use while testing, and small enough that abuse hits a wall quickly.

You can raise it in thirty seconds when real schools are using it. Raising a limit is easy. Noticing a bill is not.

### How to confirm it worked

The billing page should show your monthly limit next to the current spend. The number that matters is the limit, not the balance.

**Auto-reload will not fire once the monthly limit is reached.** That is the whole point: the limit is your real ceiling, and the card is not.

## Task 2: run migration 005

**Five minutes. This is the one real security hole on the list.**

### What it fixes

**`handle_new_user` is reachable from the internet.** It is the function that decides whether a new account is a volunteer or an organization, it runs with full database privileges, and Supabase published it as a REST endpoint automatically. Anyone could call it at `/rest/v1/rpc/handle_new_user` without signing in.

Called directly it almost certainly just errors, because it expects data a trigger provides. But "it probably errors" is not a security control, and this is the single function that assigns account roles.

**Eight functions get their search path pinned.** When a function names a table, Postgres works out which table by walking a list of schemas. Anything that can get its own object to appear earlier in that list gets used instead. Five of your eight already defended against this; the migration tightens all eight to the hardened form.

`enforce_named_verifier` is the one I would care about most. It is the trigger enforcing that nothing reaches "verified" without a named human, which is one of the strongest safeguarding guarantees you have, and it was the least protected function in the schema.

### Steps

1. Open the file `supabase/005_harden_functions.sql` in your project folder. In Terminal:

```bash
open -a TextEdit "/Users/neilmekouar/rise claude code/supabase/005_harden_functions.sql"
```

2. Select all of it and copy. **Copy the whole file, comments included.** The comments explain why each line exists, and you will want them there in a year.
3. Go to your [Supabase SQL Editor](https://supabase.com/dashboard/project/okpqytfeyjkbxgjrbaen/sql/new).
4. Paste into the empty query box.
5. Press **Run**, or Cmd+Enter.

### What you should see

The migration ends with a SELECT, so you get a table of eight rows back. Every row should show `search_path=` in the settings column.

| function | security_definer | settings |
| --- | --- | --- |
| handle_new_user | true | search_path= |
| submit_application | true | search_path= |
| submit_opportunity | true | search_path= |
| withdraw_application | true | search_path= |
| withdraw_opportunity | true | search_path= |
| enforce_named_verifier | false | search_path= |
| rise_display_name | false | search_path= |
| touch_updated_at | false | search_path= |

**`search_path=` with nothing after it is correct.** That is the empty path, which is the hardened form. If a row says `search_path=public`, that function did not take. If it says `(NOT SET)`, it definitely did not.

### Then confirm signup still works

This is the step people skip, and it is the one that catches a mistake while it is still cheap.

1. Go to [rise4impact.org](https://rise4impact.org) and create a test account with an email you can receive.
2. In Supabase, open **Table Editor** and then **profiles**.
3. **A new row should be there, with `role` set to `volunteer`.**

If the row appears, the trigger still fires and the revoke did exactly what it should: it removed the public endpoint and left the trigger alone. Delete the test account afterwards.

### Then re-run the linter

Go to **Advisors**, then **Security Advisor**, and press **Rerun linter**.

The two `handle_new_user` warnings should be gone, along with the three "Function Search Path Mutable" ones. **Five findings will remain, and all five are correct.** They are documented in `SECURITY.md` in the repo, which exists so that nobody looks at a red badge in six months and helpfully breaks the thing protecting your volunteers.

## Task 3: turn on leaked password protection

**Three minutes.**

### What it does

Supabase can check every new password against Have I Been Pwned, a database of passwords exposed in past breaches, and refuse the ones that appear there. It is currently off.

### Why this one is not generic security advice

Your users are 14 to 18, and password reuse in that group is close to universal. A student whose password leaked in some unrelated breach three years ago will type that same password into RISE without thinking about it. Their account is then takeable by anyone working through a breach list.

On most sites that means a nuisance. **On a platform that connects minors with organizations, a compromised student account is a safeguarding problem**, because of what the account can see and who it can appear to be.

**Correction, 4 October.** This guide first said to look under Policies and enable a toggle. Two things were wrong with that. There are two pages called Policies, and the one under Database is for row level security on tables, which is not this. More importantly, **leaked password protection requires the Pro plan**. You are on Free, so the setting is not hidden from you, it is not there at all.

So this task splits in two: one part you can do now for nothing, and one part that is a reason to think about Pro.

### What you can do now, free

Go to [Authentication, Sign In / Providers, Email](https://supabase.com/dashboard/project/okpqytfeyjkbxgjrbaen/auth/providers?provider=Email).

1. Set **Minimum password length** to **8**. Supabase's own documentation says anything under 8 is not recommended, and your org form currently says 6.
2. Under **Password Requirements**, require at least **lowercase, uppercase and digits**. This is free and it meaningfully raises the floor.
3. Save.

That does not stop a password that leaked in someone else's breach, which is the actual risk for teenagers. It does stop the weakest passwords.

### What needs Pro

The HaveIBeenPwned check, which refuses passwords known to appear in past breaches. That is the one worth having, and it is $25 a month on the same plan that also gives you daily backups and stops the project auto-pausing.

**Those three things are the same decision.** Backups, no auto-pause, and this. If you were weighing Pro anyway, this is the third reason.

### How to confirm it worked

Try to register a test account with the password `abc12`.

**It should be rejected for being too short.** That confirms the length rule saved.

On Free, `password123` will still be accepted. It is eleven characters, it has lowercase and digits, and nothing on this plan checks it against breach lists. That is the gap, and it is worth knowing you have it rather than assuming it is closed.

### One thing to change in the form text

The org signup form says "At least 6 characters". Once you have made this change that line is wrong, and a form that states the wrong rule produces a confusing error. Tell me when this is done and I will update the copy to match.

## Task 4: take a backup

**Fifteen minutes. This is the only item on the list that cannot be undone later.**

### Where you stand today

Your Supabase project home page says **LAST BACKUP: No backups**. That is not a misconfiguration. The Free plan does not include automatic backups at all, and Supabase's own documentation tells free-tier projects to export their own data and keep it off-site.

Right now that costs you nothing, because there are no rows worth losing. **The day a student logs their first volunteer hours, it becomes the largest risk in the whole system**, and unlike everything else on this list it is not fixable afterwards. A mistaken delete, a bad migration, or a stolen Supabase password, and it is gone.

### Get the connection string

1. Open **Project Settings**, then **Database**, in your Supabase dashboard.
2. Find **Connection string** and choose the **URI** tab.
3. Copy it. It looks like `postgresql://postgres.[ref]:[password]@...pooler.supabase.com:5432/postgres`.
4. If it shows `[YOUR-PASSWORD]` as a placeholder, you need your database password. If you do not have it, use **Reset database password** on that page and copy the new one.

**That string is as sensitive as any key on this list.** It is full read and write access to everything. Do not paste it into a chat, a document, or a website.

### Run the dump

In Terminal, with the connection string on your clipboard:

```bash
cd "/Users/neilmekouar/rise claude code" && mkdir -p ~/rise-backups && npx supabase db dump --db-url "PASTE_HERE" -f ~/rise-backups/rise-$(date +%F).sql
```

Replace `PASTE_HERE` with the string, keeping the quotation marks.

### Check it actually contains something

A zero-byte file is not a backup, and this is exactly the kind of thing that fails quietly.

```bash
ls -lh ~/rise-backups/ && grep -c "CREATE TABLE" ~/rise-backups/rise-$(date +%F).sql
```

**You want a file of real size and a count of at least 4**, since you have profiles, organizations, opportunities and applications.

### Put it somewhere that is not the Supabase account

A backup stored only inside the thing it is backing up is not a backup. Copy the file to iCloud Drive, a USB stick, or anywhere separate.

**Treat the file as sensitive.** It contains everything in the database.

### Do this bit once, and then you can stop worrying

**An untested backup is a guess.** Restore one into a scratch Supabase project at least once, so you know the file is usable and you know what restoring involves before the day you need it.

That is a twenty-minute job and worth doing before any school sees the site. Ask me and I will walk you through it.

### Repeat until it is automatic

Run the dump again whenever something meaningful is in the database. Before launch, either automate it with a scheduled job, or move to the Pro plan, which includes seven days of daily backups and also solves the auto-pausing problem.

## Final check

Paste this when all four are done. It checks the three things that can be checked from outside.

```bash
cd "/Users/neilmekouar/rise claude code"
echo "site:   $(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 https://rise4impact.org)"
echo "admin:  $(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST https://rise4impact.org/api/admin -H 'Content-Type: application/json' --data '{"action":"get-bar"}')"
curl -sS --max-time 20 -X POST https://rise4impact.org/api/ai-search -H 'Content-Type: application/json' --data '{"action":"ping"}'
echo
ls -lh ~/rise-backups/ 2>/dev/null || echo "NO BACKUP YET"
```

### What each answer means

| Line | Want to see | If it says otherwise |
| --- | --- | --- |
| site | `200` | The site is down. Tell me. |
| admin | `200` | `500` means the service key is missing again |
| guards | both `true` | **A `false` means your spend cap is per data centre again** |
| backup | a file with real size | Task 4 did not finish |

The guards line is the one to look at. Both counters fall back to per-isolate when a binding goes missing, and that fallback is deliberately silent so the site keeps working. Silent is what makes it worth checking: a spend cap that has quietly reverted looks identical from outside.

### Worth re-running

After any deploy that changes `wrangler.toml`, and once a month out of habit. It takes five seconds.

### Tasks

- [ ] 1. Anthropic monthly spend limit set
- [ ] 2. Migration 005 run, eight rows all showing `search_path=`
- [ ] 2b. Test signup confirmed, a row appeared in profiles
- [ ] 3. Password length 8 and character rules on, a too-short password rejected (the breach check needs Pro)
- [ ] 4. Backup taken, checked for size, copied off the Supabase account
- [ ] 4b. A backup restored into a scratch project, once

## If something goes wrong

None of these four can break the live site. Tasks 1 and 3 are account settings, task 4 only reads. Task 2 writes to the database, and it is the only one worth being careful with.

### Migration 005

| Error | What happened | What to do |
| --- | --- | --- |
| `function ... does not exist` | A signature does not match your database | Stop and send me the full line. Do not edit the signature to make it pass. |
| `permission denied` | The SQL Editor is not running as owner | Make sure you are in the right project and signed in as yourself |
| Rows still show `search_path=public` | Some `alter` lines did not run | Safe to run the whole file again |
| Rows show `(NOT SET)` | The alters did not apply | Run the file again and send me the output |

**The whole file is safe to run twice.** `revoke` on something already revoked and `alter function` to a value already set both succeed without doing anything.

### If signup breaks after task 2

This should not happen. A trigger resolves its privileges through its owner, not through whoever caused it to fire, so revoking the REST endpoint leaves the trigger alone.

If it does break, this undoes just that part:

```sql
grant execute on function public.handle_new_user() to anon, authenticated;
```

Then tell me, because it would mean something about the trigger is different from what the migration file says, and I would want to understand it rather than leave a public endpoint open.

### If the backup command fails

| Message | Cause |
| --- | --- |
| `password authentication failed` | Wrong password in the string. Reset it in Project Settings and copy the new one. |
| `could not translate host name` | The connection string got cut off when pasting |
| `command not found: npx` | Node is not installed, or Terminal is in the wrong folder |
| Finishes instantly, tiny file | Usually an auth failure that did not report cleanly. Check the file size. |

### What is safe to retry

**All of it.** Setting a spend limit twice, running 005 twice, toggling the password setting, taking a second backup: none of them does damage. If you are unsure whether something worked, do it again and check the output rather than assuming.

### If you get stuck

Paste me the exact output, including the error text. The specific message is what identifies the problem, and a summary of it usually is not.

The one thing I would ask you not to do is edit the SQL to make an error go away. An error there is information, and it is much cheaper to understand it now than to find out later that a safeguarding trigger has not been running.
