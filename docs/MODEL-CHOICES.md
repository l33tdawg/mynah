# Which model Mynah picks, and why

The owner picks a **provider**. Mynah picks the **model**.

This file is the reasoning behind those picks. Model names age out within
months — three of ours already have, see *Stale names found* below — so the
reasoning is written down here rather than left as a string constant with no
explanation next to it.

## Why the owner does not pick the model

A model name is not a choice a person can make well. It is a lookup against a
catalogue that changes without notice, in a vocabulary the owner has no reason
to have learned, where a wrong answer does not fail loudly — it fails as an
appliance that takes a question and never answers. The owner who types a model
name a year from now is not making a mistake anybody could have warned them
about at the moment they made it.

What the owner does know, and can be asked, is who they hold an account with.
That is the whole of what setup asks now.

## What gets offered

**Offer what we have measured. Omit what we have not.**

Not a flat catalogue of everything that could work, and not a curation based on
*"providers a non-technical owner has plausibly heard of"* — that earlier rule
encoded an assumption about who the owner is, produced a US-shaped list, and was
self-fulfilling, because you cannot choose a provider you are never shown.

The replacement curates on evidence we can gather rather than on taste. A voice
appliance whose picker offers a brain it then refuses to call through is the
picker and the caller disagreeing about what the product is.

## What "the right model" means here

This is an appliance you talk to. In that order:

1. **It has to hold a conversation at conversational speed.** A reply that
   arrives after twenty seconds is not a reply, it is a timeout with text
   attached. This rules out the top of every vendor's range regardless of how
   much better it reasons.
2. **It has to route tools correctly.** Mynah's answers come from SAGE — its
   memory, its tasks, its agents. A model that talks fluently and never calls a
   tool is worse than one that refuses, because it will confidently answer from
   nothing. This is the property that fails silently and therefore the one worth
   testing.
3. **Then, and only then, cheapest.** The owner pays per token for a device that
   sits there all day. Cost is a real constraint, but it is the tiebreak.

(1) and (3) point the same way; (2) does not. Cheap fast models are exactly
where tool routing gets unreliable, so (2) has to be checked rather than assumed.

## What "measured" has to mean

**Not a vibe and not a vendor claim.** Time to first token and time to a
complete short answer, on the owner's machine, against the same prompt — the
thing that decides whether a call works.

This is worth stating plainly because vendor speed figures are seductive and
several appear in the notes below. Groq publishes 560 tokens/sec for
`llama-3.1-8b-instant`. That number is a reason to *go and measure*; it is not a
measurement, and it is not what this table records.

## The picks

| Provider | Model | Grounded | Offered | Checked |
|---|---|---|---|---|
| Anthropic | `claude-haiku-4-5` | vendor catalogue | **yes** — in use and known | 2026-07-29 |
| OpenAI | `gpt-5.6-luna` | vendor catalogue | **yes** — in use and known | 2026-07-29 |
| DeepSeek | `deepseek-v4-flash` | vendor catalogue | **yes** — owner's own evidence | 2026-07-29 |
| Groq | `llama-3.1-8b-instant` | vendor catalogue | no — unmeasured | 2026-07-29 |
| Kimi (Moonshot) | *not settled* | — | no — unmeasured | 2026-07-29 |
| GLM (Zhipu) | *not confirmed on our endpoint* | — | no | 2026-07-29 |

**Grounded** means the id was read off the vendor's own current catalogue on the
date shown, not recalled. **Offered** is a separate question and a higher bar:
naming a model is not measuring it.

### Anthropic — `claude-haiku-4-5`

The fast tier: $1/$5 per million tokens against `claude-sonnet-5` at $3/$15,
with full tool use. 200K context, far more than a spoken conversation reaches.
Cheapest thing in the range that meets (1) and (2), which is the rule applied
exactly.

### OpenAI — `gpt-5.6-luna`

$1/$6, the cost-optimised tier of the current frontier family (`gpt-5.6-sol` at
$5/$30, `gpt-5.6-terra` at $2.50/$15). Function calling supported. Same shape of
argument as Anthropic: the cheap end of a family whose whole range holds a
conversation.

### DeepSeek — `deepseek-v4-flash`

$0.14/$0.28 per million on a cache miss, $0.0028 cached — an order of magnitude
below everything else here. Offered on the owner's direct evidence: he uses it
and reports it fast. That counts, and it is better evidence than a spec sheet.

### Groq — `llama-3.1-8b-instant`, named but not offered

Groq's whole proposition is speed and the published figure is 560 tokens/sec,
with tool use explicitly supported. It would be easy to wave this through on
that basis. It stays out because a vendor's tokens/sec is not the measurement
this table requires, and expecting is what this project has repeatedly been
wrong about. **This is the row most likely to move**, and moving it is one
measurement's work, not an implementation's.

### Kimi and GLM — not settled

**Kimi:** the fast variant is `kimi-k2.7-code-highspeed` (~180 tokens/sec), but
it is a *coding* specialist and this is a conversational appliance, so it is the
wrong shape even though it is the fast one. The general models are `kimi-k3`,
`kimi-k2.6`, `kimi-k2.5`. Tool-use support is not documented on the model list.
Nothing here is a confident pick yet.

**GLM:** `GLM-5-Turbo` exists and is described as optimised for agent workflows
and tool use, at roughly $1.20/$4. But our backend talks to
`open.bigmodel.cn/api/paas/v4`, and the id confirmed above was on a third-party
router with its own namespace. **An id that is correct somewhere else is not a
grounded id here**, so the row stays blank.

A blank row is not an unfinished doc. It is the reason that provider is absent
from the picker, and it should be read that way.

## Stale names found while doing this

Three model names already in the codebase have expired. Recording them because
they are the argument for this file existing:

| Name in repo | Status |
|---|---|
| `kimi-k2-0905-preview` | **deprecated** by Moonshot |
| `gpt-5` | superseded by the `gpt-5.6-*` family |
| `llama-3.3-70b-versatile` | still serves tools, but at 280 tok/s — half `llama-3.1-8b-instant` |

None of these caused a visible failure, because none is on a path an owner
reaches today. That is exactly how the next one will arrive too.

## What catches it when a name here goes stale

Two mechanisms, both running against the owner's own key rather than against a
measurement somebody took once:

- **`BrainKeyValidator` (`Setup/APIKeyOnboarding.swift`)** sends one real request
  carrying one real tool and checks the model actually called it. If it replies
  but ignores the tool, the verdict is `.unusable` and the owner is told so in
  the sheet, at the moment they paste the key — not hours later as silence.
  That is criterion (2), tested per owner, per provider, against the provider's
  catalogue as it is that day.

- **`BrainAvailability` via `OpenAICompatBackend.availability()`** lists
  `/v1/models` and reports `modelNotOffered(model:offered:)` when our pick is not
  in the account's catalogue — carrying what *was* offered, which is what turns
  the failure into something the next maintainer can act on.

When a vendor retires a name in this table, `Verdict.modelGone` fires at
selection time and says so plainly: *the key is fine, this build's model is
gone, this needs a Mynah update rather than anything from you.* No retry button,
because there is nothing for the owner to retry.

That check used to exist and return a bare `Bool`, so a retired model was
indistinguishable from a bad key, an expired card, and dropped Wi-Fi. That is
the failure this table is the first line of defence against and the validator is
the second.

## When you change a pick

Change the reasoning too. If a row says a model was chosen for speed and tool
routing and you swap it, the next person needs to know whether the old one was
withdrawn, was too slow, or stopped calling tools — three different next moves.

And if you cannot verify an id against **the endpoint we actually call**, leave
the row blank and say so. That is what the blanks above are.
