# Playing in the Wild: External Platform Connectivity

This document covers how to connect the RBM poker bot to external poker
platforms, competition servers, and evaluation frameworks.  The bot trains
Limit Hold'em strategies via external-sampling MCCFR; the interfaces below
let you pit those strategies against other bots and benchmarks.

---

## Table of Contents

1. [ACPC Dealer (Annual Computer Poker Competition)](#1-acpc-dealer)
2. [OpenSpiel (Google DeepMind)](#2-openspiel)
3. [Slumbot](#3-slumbot)
4. [Hand Evaluation Libraries](#4-hand-evaluation-libraries)
5. [Other Poker Platforms](#5-other-poker-platforms)

---

## 1. ACPC Dealer

The **Annual Computer Poker Competition** defined the standard protocol for
computer poker research.  The open-source dealer server manages games between
two (or more) bots over TCP.

### 1.1 The Protocol

The ACPC protocol is line-oriented over TCP.  Each line is terminated by
`\r\n`.

**Dealer -> Client (MATCHSTATE)**

```
MATCHSTATE:<position>:<hand_number>:<betting>:<cards>
```

| Field         | Type   | Description                                        |
|---------------|--------|----------------------------------------------------|
| `position`    | int    | 0 = small blind / first to act preflop; 1 = big blind |
| `hand_number` | int    | Monotonically increasing hand counter              |
| `betting`     | string | Action history: `r` raise, `c` call/check, `f` fold. Streets separated by `/`. |
| `cards`       | string | Pipe-separated card groups: `hole|flop|turn|river`. Hidden opponent cards are omitted. |

**Client -> Dealer (Response)**

When it is the client's turn, respond with the original MATCHSTATE line,
a colon, and the chosen action character:

```
MATCHSTATE:0:42:cr:|AhKd:r
```

Action characters: `f` (fold), `c` (call/check), `r` (raise/bet).

**When NOT to respond**: if `position` does not match the acting player for the
current betting state, the dealer does not expect a response.  Sending one
will desynchronize the protocol.

**Card encoding**: ranks `23456789TJQKA`, suits `cdhs`.  Example: `Ah` = Ace
of hearts, `Td` = Ten of diamonds.

**Betting examples**:

| Betting String | Meaning                                          |
|----------------|--------------------------------------------------|
| (empty)        | Preflop, first to act                            |
| `r`            | Preflop, player 0 raised                         |
| `rc`           | Preflop, P0 raised, P1 called -> flop            |
| `rc/`          | Flop, no actions yet                             |
| `rc/cr`        | Flop, P0 checked, P1 bet                        |
| `crc/cc/cc/cr` | River, P0 checked, P1 bet                       |

### 1.2 Setting Up the Dealer Locally

**Repository**: <https://github.com/jblespiau/project_acpc_server>

```bash
git clone git@github.com:jblespiau/project_acpc_server.git
cd project_acpc_server
make
```

This produces:
- `dealer` -- the game server
- `example_player` -- a sample random bot (C)

**Game definition files** are in `game_defs/`.  For Limit Hold'em heads-up:

```bash
cat game_defs/holdem.limit.2p.reverse_blinds.game
```

```
GAMEDEF
limit
numPlayers = 2
numRounds = 4
firstPlayer = 1 1 1 1
maxRaises = 4 4 4 4
numSuitsDeck = 4
numRanksDeck = 13
numHoleCards = 2
numBoardCards = 0 3 1 1
raiseSize = 2 2 4 4
blind = 1 2
END GAMEDEF
```

### 1.3 Running a Match

Start the dealer, specifying the game definition, a log file, and ports
for each player:

```bash
# 1000-hand match, seed 42, players on ports 20000 and 20001
./dealer game_defs/holdem.limit.2p.reverse_blinds.game \
    match_log.txt 1000 42 \
    Player1 Player2 \
    -p 20000,20001
```

The dealer listens on the specified ports.  Each bot connects as a TCP
client.

### 1.4 Connecting Our Bot

**TCP bot** (`bin/acpc_tcp_bot.ml`):

```bash
# Train for 50k iterations, then connect to the dealer on port 20000
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --train 50000

# Or load a pre-trained strategy
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --strategy trained.bin

# Save strategy after training for reuse
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --train 100000 --save trained.bin

# Verbose mode (logs every action)
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --strategy trained.bin --verbose
```

**Command-line options**:

| Flag          | Default     | Description                                    |
|---------------|-------------|------------------------------------------------|
| `--host`      | `localhost` | Dealer hostname or IP                          |
| `--port`      | `20000`     | Dealer TCP port                                |
| `--train`     | 0           | MCCFR iterations before connecting             |
| `--strategy`  | (none)      | Load serialized strategy from file             |
| `--buckets`   | 10          | Preflop abstraction bucket count               |
| `--save`      | (none)      | Save trained strategy to file                  |
| `--verbose`   | false       | Log every action to stderr                     |

**Full local match example** (two terminal windows):

```bash
# Terminal 1: start dealer
cd project_acpc_server
./dealer game_defs/holdem.limit.2p.reverse_blinds.game \
    match.log 10000 0 RBM_Bot Random_Bot -p 20000,20001

# Terminal 2: connect our bot as Player 1 (port 20000)
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --train 50000

# Terminal 3: connect random baseline as Player 2 (port 20001)
cd project_acpc_server
./example_player game_defs/holdem.limit.2p.reverse_blinds.game localhost 20001
```

### 1.5 Stdin Bot (for piped testing)

The original `acpc_bot.exe` reads MATCHSTATE lines from stdin, useful for
unit testing without a dealer:

```bash
echo "MATCHSTATE:0:0::|AhKd" | \
    opam exec -- dune exec -- rbm-acpc-bot --train 10000
```

### 1.6 Protocol Implementation Details

Our implementation lives in two files:

- **`lib/acpc_protocol.ml`** -- Pure protocol parser.  Handles MATCHSTATE
  parsing, action formatting, betting history analysis, turn detection,
  terminal state detection, and conversion from ACPC to internal history
  format (e.g., ACPC `c` after a bet becomes internal `c` for call, but
  ACPC `c` with no bet outstanding becomes internal `k` for check).

- **`bin/acpc_tcp_bot.ml`** -- TCP client.  Opens a socket via
  `Core_unix.socket`/`connect`, reads lines byte-by-byte (the ACPC dealer
  uses `\r\n` termination), selects actions via the trained strategy, and
  writes responses.

---

## 2. OpenSpiel

**OpenSpiel** is Google DeepMind's framework for research in games, including
several poker variants.

**Repository**: <https://github.com/google-deepmind/open_spiel>

### 2.1 Supported Poker Games

| Game ID                       | Variant                        |
|-------------------------------|--------------------------------|
| `kuhn_poker`                  | Kuhn poker (3-card, 1 round)   |
| `leduc_poker`                 | Leduc Hold'em (6-card, 2 rounds) |
| `universal_poker`             | Configurable poker (limit/NL, any # players) |
| `tiny_hanabi`                 | Hanabi variant                 |

The `universal_poker` game supports full Texas Hold'em in both limit and
no-limit variants with configurable parameters.

### 2.2 Installation

```bash
# Python package (includes C++ backend)
pip install open_spiel

# Or build from source for C++ API access
git clone git@github.com:google-deepmind/open_spiel.git
cd open_spiel
pip install -e .
```

### 2.3 Using as a Baseline

OpenSpiel includes several CFR implementations we can benchmark against:

- **CFR** (vanilla tabular)
- **CFR+** (regret-matching+, faster convergence)
- **External Sampling MCCFR** (same algorithm as our implementation)
- **Outcome Sampling MCCFR**
- **Deep CFR** (neural network function approximation)

**Training a baseline in Python**:

```python
import pyspiel
from open_spiel.python.algorithms import cfr

# Create a limit hold'em game
game = pyspiel.load_game("universal_poker", {
    "betting": "limit",
    "numPlayers": 2,
    "numRounds": 4,
    "blind": "1 2",
    "raiseSize": "2 2 4 4",
    "maxRaises": "4 4 4 4",
    "numSuits": 4,
    "numRanks": 13,
    "numHoleCards": 2,
    "numBoardCards": "0 3 1 1",
})

# Train with CFR+
solver = cfr.CFRPlusSolver(game)
for i in range(10000):
    solver.evaluate_and_update_policy()

avg_policy = solver.average_policy()
```

### 2.4 Connecting Our Bot via Subprocess

The cleanest integration wraps our OCaml bot as a subprocess that an
OpenSpiel Python harness drives.  The harness translates OpenSpiel game
states into MATCHSTATE strings, pipes them to the bot, and reads actions
back:

```python
import subprocess
import pyspiel

class OCamlBotPlayer:
    """Wraps the RBM acpc_bot as a subprocess."""

    def __init__(self, bot_path, strategy_file):
        self.proc = subprocess.Popen(
            [bot_path, "--strategy", strategy_file],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def step(self, matchstate_line):
        """Send a MATCHSTATE line and read the response action."""
        self.proc.stdin.write(matchstate_line + "\n")
        self.proc.stdin.flush()
        response = self.proc.stdout.readline().strip()
        # Response format: "MATCHSTATE:...:action"
        return response.split(":")[-1]

    def close(self):
        self.proc.terminate()
```

A more complete integration would translate OpenSpiel's `State` objects
to/from ACPC MATCHSTATE format.  See `lib/acpc_protocol.ml` for the
format specification.

### 2.5 Exploitability Measurement

OpenSpiel provides exploitability computation for small games, which
measures how far a strategy is from Nash equilibrium:

```python
from open_spiel.python.algorithms import exploitability

# After training
expl = exploitability.exploitability(game, avg_policy)
print(f"Exploitability: {expl:.6f} (mbb/g)")
```

For full Hold'em this is intractable, but for Kuhn and Leduc poker it
provides ground truth validation of our CFR implementation.

---

## 3. Slumbot

**Slumbot** (<http://www.slumbot.com/>) is a public heads-up no-limit
Hold'em bot created by Eric Jackson.  It provides a REST API for playing
hands programmatically -- one of the few publicly available NL Hold'em
opponents.

**Status**: WORKING -- `bin/slumbot_client.ml` connects and plays.

### 3.1 API Overview

| Endpoint                    | Method | Description                     |
|-----------------------------|--------|---------------------------------|
| `/slumbot/api/login`        | POST   | Authenticate (optional)         |
| `/slumbot/api/new_hand`     | POST   | Start a new hand                |
| `/slumbot/api/act`          | POST   | Take an action in current hand  |

**Base URL**: `https://slumbot.com`

**Game parameters**: 50/100 blinds, 20,000 chip stack (200 BB), heads-up NL.

### 3.2 Starting a Hand

```bash
curl -X POST https://slumbot.com/slumbot/api/new_hand \
    -H "Content-Type: application/json" \
    -d '{}'
```

**Response**:

```json
{
    "token": "57b08c4b-daae-43fd-aa1a-2c6a908cebc3",
    "action": "b200",
    "client_pos": 0,
    "hole_cards": ["8s", "5c"],
    "board": [],
    "winnings": null
}
```

**Token**: pass into every subsequent request.  The token may change between
responses; always use the latest one.

**client_pos**: 0 = big blind (first to act postflop, second preflop),
1 = small blind (first to act preflop, second postflop).

**Cards**: standard ACPC format strings (e.g., "Ac" = Ace of clubs).

**action**: the Slumbot bot's action so far.  If the bot acts first (client
is BB and bot opens), this will already contain the bot's preflop action.

### 3.3 Taking an Action

```bash
curl -X POST https://slumbot.com/slumbot/api/act \
    -H "Content-Type: application/json" \
    -d '{"token": "57b08c4b-...", "incr": "c"}'
```

**Action encoding**:
- `k` -- check
- `c` -- call
- `f` -- fold
- `b{N}` -- bet/raise to N chips (street-relative; see below)

**Bet sizes** are the total amount a player has put in *on that street*.
For example, `b200c/kb400` means: preflop bet 200, called; flop check,
bet 400 (pot-sized since pot = 400 after preflop).

**Response** has the same shape as `new_hand`, with `winnings` set to an
integer when the hand is complete.  Response also includes `bot_hole_cards`
at showdown.

### 3.4 OCaml Client

**Binary**: `bin/slumbot_client.ml` (`rbm-slumbot-client`)

This is a fully working client that:
1. Trains an NL MCCFR strategy (or loads from file)
2. Connects to Slumbot's REST API via curl subprocess
3. Plays configurable hands, mapping strategy actions to Slumbot bet sizes
4. Reports results in mbb/hand

```bash
# Train and play 100 hands against real Slumbot
opam exec -- dune exec -- rbm-slumbot-client --train 50000 --hands 100

# Save strategy for reuse
opam exec -- dune exec -- rbm-slumbot-client --train 50000 --save strat_nl.bin --hands 200

# Load saved strategy
opam exec -- dune exec -- rbm-slumbot-client --strategy strat_nl.bin --hands 500

# Mock mode (local check/call bot, no network)
opam exec -- dune exec -- rbm-slumbot-client --mock --train 5000 --hands 50

# Verbose mode
opam exec -- dune exec -- rbm-slumbot-client --train 10000 --hands 20 --verbose

# With Slumbot account (for tracked sessions)
opam exec -- dune exec -- rbm-slumbot-client --strategy strat_nl.bin \
    --username myuser --password mypass --hands 1000
```

**Command-line options**:

| Flag          | Default | Description                                    |
|---------------|---------|------------------------------------------------|
| `--train`     | 0       | NL MCCFR iterations before playing             |
| `--strategy`  | (none)  | Load serialized NL strategy from file          |
| `--save`      | (none)  | Save trained strategy to file                  |
| `--buckets`   | 10      | Preflop abstraction bucket count               |
| `--hands`     | 100     | Number of hands to play                        |
| `--mock`      | false   | Use local mock bot instead of real API         |
| `--verbose`   | false   | Log every action to stderr                     |
| `--username`  | (none)  | Slumbot account username                       |
| `--password`  | (none)  | Slumbot account password                       |

**Strategy mapping**: Since Slumbot uses continuous bet sizes and our MCCFR
uses bucketed fractions (0.5x, 1.0x, 2.0x pot), the client maps between them:
- Internal `h` (half-pot) -> `b{N}` where N = 0.5 * pot
- Internal `p` (pot) -> `b{N}` where N = pot
- Internal `d` (double-pot) -> `b{N}` where N = 2 * pot
- Internal `a` (all-in) -> `b{stack_remaining}`
- Slumbot bets are mapped to nearest fraction for info-set lookup

### 3.5 Testing Against Slumbot

Recommended pipeline:

```bash
# 1. Train a strong strategy (more iterations = stronger)
opam exec -- dune exec -- rbm-slumbot-client \
    --train 200000 --buckets 15 --save strategy_200k.bin --mock --hands 1

# 2. Play against Slumbot
opam exec -- dune exec -- rbm-slumbot-client \
    --strategy strategy_200k.bin --hands 1000

# 3. Compare different bucket counts
for b in 5 10 15 20; do
  opam exec -- dune exec -- rbm-slumbot-client \
      --train 100000 --buckets $b --hands 200
done
```

**Expected performance**: With limited training (5-50K iterations) and
coarse abstraction (10 buckets), the bot will likely lose to Slumbot
(a near-optimal HUNL solver).  The value is in measuring the loss rate
and comparing abstraction methods.

---

## 4. Hand Evaluation Libraries

External hand evaluation libraries can validate our `Hand_eval5` and
`Hand_eval7` implementations.

### 4.1 PokerStove

**Repository**: <https://github.com/andrewprock/pokerstove>

PokerStove provides:
- 5-card and 7-card hand evaluation
- Equity calculation (Monte Carlo and exhaustive enumeration)
- Hand range analysis

```bash
git clone git@github.com:andrewprock/pokerstove.git
cd pokerstove
cmake -B build && cmake --build build
```

**Validation approach**: generate all `C(52,5) = 2,598,960` five-card
hands, evaluate with both our `Hand_eval5` and PokerStove, and verify
identical rankings.

### 4.2 poker-eval (libpoker-eval)

The classic C library used by PokerStars and many bots.

```bash
# Debian/Ubuntu
sudo apt install libpoker-eval-dev

# Or from source
git clone git@github.com:atinm/poker-eval.git
cd poker-eval && autoreconf -fi && ./configure && make
```

### 4.3 Validation Script Outline

```bash
# Generate reference hand rankings
opam exec -- dune exec -- rbm-test-equity 2>&1 | head -20

# Compare against external evaluator (if pokerstove is built)
./pokerstove/build/bin/ps-eval --hand "AhKd" --board "Qh Jh Th 2c 3s"
```

Our `Hand_eval7.evaluate` returns `(rank_class, tiebreaker)` which should
produce the same total ordering as any standards-compliant evaluator.  The
test binary `rbm-test-equity` already exercises this.

---

## 5. Other Poker Platforms

### 5.1 Platforms That Permit Bots

| Platform                | Variant     | Bot-Friendly | Notes                               |
|-------------------------|-------------|:------------:|---------------------------------------|
| ACPC Dealer (local)     | Limit/NL    | Yes          | Research standard, fully open        |
| Slumbot                 | HUNL        | **WORKING**  | REST API, free, rate-limited         |
| OpenSpiel               | Any         | Yes          | Framework, not a platform            |
| PokerRL                 | NL          | Yes          | Reinforcement learning framework     |
| Poker Academy           | Limit/NL    | Yes          | Commercial, has bot API (Meerkat)    |
| CleverPiggy NL Bot      | HUNL        | Partial      | Web-based, no documented API         |
| DecisionHoldem          | HUNL        | Yes          | Open source, depth-limited solving   |

### 5.2 Platforms That Ban Bots

**PokerStars**, **GGPoker**, **partypoker**, and all major real-money
platforms **explicitly prohibit** automated play.  Their Terms of Service
forbid:
- Automated decision-making
- Screen scraping / OCR
- Input injection
- Any software that replaces human judgment

Violation results in account closure and fund seizure.  **Do not connect
our bot to real-money platforms.**

### 5.3 Play Money / Research Options

For testing against human-like opponents without violating ToS:

- **Private home games**: Some platforms (PokerStars Home Games, ClubGG)
  allow private clubs.  In a private setting with informed participants,
  a bot can be run for research with consent.
- **Play money tables**: Most sites have play money modes.  While technically
  still ToS violations, enforcement is lax.  Not recommended for serious
  research since play money opponents behave very differently from
  real-money players.
- **Local dealer + human UI**: Run the ACPC dealer locally, connect our
  bot on one port, and a human-controlled client on the other.  This is the
  cleanest option for human-vs-bot evaluation.

### 5.4 PokerRL

**Repository**: <https://github.com/TinzeyZheng/PokerRL>

A reinforcement learning framework for NL Hold'em.  Includes:
- Environment wrappers for NL Texas Hold'em
- Deep CFR and Neural Fictitious Self-Play implementations
- Evaluation against baseline bots

Could serve as another benchmark opponent for our NL strategy once
`Cfr_nolimit` is implemented.

---

## Recommended Getting Started Path

For the fastest path to playing in the wild:

### Step 1: Train a strong strategy

```bash
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --train 200000 --buckets 20 --save strategy_200k.bin \
    --host localhost --port 99999 2>&1 | head -5
# (will fail to connect, but saves the strategy)
```

Or train and save without connecting:

```bash
opam exec -- dune exec -- rbm-acpc-bot \
    --train 200000 --buckets 20 --save strategy_200k.bin < /dev/null
```

### Step 2: Test against the ACPC random player locally

```bash
# Clone and build the dealer
git clone git@github.com:jblespiau/project_acpc_server.git
cd project_acpc_server && make

# Run a 10,000-hand match
./dealer game_defs/holdem.limit.2p.reverse_blinds.game \
    results.log 10000 0 RBM Random -p 20000,20001 &

# Connect our bot (seat 1)
opam exec -- dune exec -- rbm-acpc-tcp-bot \
    --host localhost --port 20000 --strategy strategy_200k.bin &

# Connect the random player (seat 2)
./example_player game_defs/holdem.limit.2p.reverse_blinds.game localhost 20001

# Analyze results
tail -1 results.log
```

### Step 3: Measure exploitability on a small game

Use OpenSpiel to compute exploitability on Kuhn or Leduc poker, validating
that our CFR implementation converges correctly.

### Step 4: Graduate to NL

Implement `Cfr_nolimit` (the `.mli` is already defined), then connect to
Slumbot via the REST API for heads-up no-limit evaluation.

---

## Architecture Reference

```
bin/acpc_bot.ml       -- Stdin/stdout ACPC bot (for piped testing)
bin/acpc_tcp_bot.ml   -- TCP ACPC bot (for dealer server connection)
lib/acpc_protocol.ml  -- ACPC protocol parser (MATCHSTATE <-> internal)
lib/cfr_abstract.ml   -- External-sampling MCCFR trainer
lib/abstraction.ml    -- Equity-based card abstraction
lib/limit_holdem.ml   -- Limit Hold'em game rules
lib/nolimit_holdem.ml -- No-Limit Hold'em game rules
lib/cfr_nolimit.mli   -- NL MCCFR interface (implementation pending)
lib/hand_eval5.ml     -- 5-card hand evaluation
lib/hand_eval7.ml     -- 7-card hand evaluation (best of C(7,5))
lib/equity.ml         -- Preflop equity / canonical hand forms
```
