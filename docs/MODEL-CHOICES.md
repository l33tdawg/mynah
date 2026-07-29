# Which model Mynah picks, and why

The owner picks a **provider**. Mynah picks the **model**.

This file is the reasoning behind those picks. Model names age out within
months; the reasoning is what survives, so it is written down here rather than
left as a string constant with no explanation next to it.

## Why the owner does not pick the model

The model field was removed from setup, and the reason is not simplification for
its own sake.

A model name is not a choice a person can make well. It is a lookup against a
catalogue that changes without notice, in a vocabulary the owner has no reason
to have learned, where a wrong answer does not fail loudly — it fails as an
appliance that takes a question and never answers. The owner who types
`gpt-4o` into a field a year from now is not making a mistake anybody could have
warned them about at the moment they made it.

What the owner does know, and can be asked, is who they hold an account with.
That is the whole of what setup asks now.

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
3. **Then, and only then, cheapest.** The owner pays per token for a device
   that sits there all day. Cost is a real constraint, but it is the tiebreak,
   not the criterion.

Note that (1) and (3) point the same way and (2) does not. Cheap fast models are
exactly where tool routing gets unreliable, so (2) is the one that has to be
checked rather than assumed.

## How the pick is checked — this already exists

Two mechanisms already in the code do most of this work, and both run against
the owner's own key rather than against a measurement somebody took once:

- **`BrainKeyValidator` (`Setup/APIKeyOnboarding.swift`)** sends one real
  request carrying one real tool and checks whether the model actually called
  it. If it replies but ignores the tool, the verdict is `.unusable` and the
  owner is told so in the sheet, at the moment they paste the key — not hours
  later as silence. This is criterion (2), tested per owner, per provider,
  against the provider's catalogue as it is that day.

- **`OpenAICompatBackend.isAvailable()`** lists `/v1/models` and checks the
  model we asked for is actually offered to that account.

Between them they cover the thing that makes a hardcoded model name survivable:
**when our pick is withdrawn by the vendor, that is discovered at selection time
and said out loud, rather than becoming a device that stopped working.**

### The gap, named

`isAvailable()` returns `Bool`. A 200 from `/models` whose list does not contain
our model is a specific and true sentence about the provider — *"this account no
longer offers the model Mynah picks"* — and it currently collapses into the same
`false` as a rejected key, an expired card, and a dropped network.

That is an absence being read as an answer, and it is the failure the owner
would experience as "Mynah is broken". Distinguishing it is the outstanding
work; the check itself is already there.

## The picks

| Provider | Model | Grounded? |
|---|---|---|
| Anthropic | `claude-haiku-4-5` | Yes — vendor catalogue, 2026-07 |
| OpenAI | *not yet chosen* | — |
| DeepSeek | *not yet chosen* | — |
| Kimi (Moonshot) | *not yet chosen* | — |
| Groq | *not yet chosen* | — |
| GLM (Zhipu) | *not yet chosen* | — |

**Anthropic — `claude-haiku-4-5`.** The fast tier: $1/$5 per million tokens
against `claude-sonnet-5` at $3/$15, with full tool use. 200K context, which is
far more than a spoken conversation reaches. It meets (1) and (2) and is the
cheapest thing in the range that does, which is the rule stated above applied
exactly. Verified against the vendor's published catalogue rather than recalled.

**Everything else is deliberately blank.** Not an oversight and not a TODO
somebody forgot — an unverified model ID written into this table would be
indistinguishable from a verified one, and the next person would have no way to
tell which of these had been checked. A blank is honest; a plausible guess is
not. Each is filled in by reading that vendor's current catalogue and confirming
the pick through the validator above.

## When you change a pick

Change the reasoning too. If a row here says a model was chosen for speed and
tool routing, and you swap it for something else, the next person needs to know
whether the old model was withdrawn, was too slow, or stopped calling tools —
those lead to three different next moves.

And if you find yourself unable to verify a model ID from the vendor: leave the
row blank and say so. That is what the blanks above are.
