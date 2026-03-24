/// Slumbot API client for heads-up no-limit Hold'em.
///
/// Plays against Slumbot (https://slumbot.com) using a trained NL MCCFR
/// strategy. Communicates via Slumbot's REST API (JSON over HTTPS).
///
/// Slumbot game parameters:
/// - Blinds: 50/100
/// - Stack: 20,000 chips (200 BB)
/// - Heads-up no-limit Hold'em
///
/// API endpoints (base: https://slumbot.com):
/// - POST /slumbot/api/new_hand   -- start a new hand
/// - POST /slumbot/api/act        -- take an action
///
/// Action encoding:
/// - "k"      = check
/// - "c"      = call
/// - "f"      = fold
/// - "b{N}"   = bet/raise to N chips (street-relative)
///
/// Card encoding: standard ACPC format (e.g., "Ac" = Ace of clubs).
///
/// client_pos: 0 = big blind (acts second preflop, first postflop),
///             1 = small blind (acts first preflop, second postflop).

use std::path::Path;

use rustc_hash::FxHashMap;
use serde_json::Value;

use crate::buckets;
use crate::card::{self, Card};
use crate::config::GameConfig;
use crate::info_key;

// --------------------------------------------------------------------------
// Constants matching Slumbot's game
// --------------------------------------------------------------------------

const SLUMBOT_SMALL_BLIND: i32 = 50;
const SLUMBOT_BIG_BLIND: i32 = 100;
const SLUMBOT_STACK: i32 = 20_000;
const SLUMBOT_BASE_URL: &str = "https://slumbot.com/slumbot/api";

// --------------------------------------------------------------------------
// Strategy type
// --------------------------------------------------------------------------

/// Averaged strategy: info_key -> probability distribution over actions.
pub type Strategy = FxHashMap<u64, Vec<f32>>;

/// Load averaged strategy from the binary checkpoint format.
/// Returns [p0_strategy, p1_strategy].
pub fn load_strategy(path: &Path) -> std::io::Result<[Strategy; 2]> {
    let raw = crate::checkpoint::load_averaged_strategy(path)?;
    let mut result = [
        FxHashMap::with_capacity_and_hasher(raw[0].len(), Default::default()),
        FxHashMap::with_capacity_and_hasher(raw[1].len(), Default::default()),
    ];
    for player in 0..2 {
        for (key, probs) in &raw[player] {
            result[player].insert(*key, probs.iter().map(|&p| p as f32).collect());
        }
    }
    Ok(result)
}

// --------------------------------------------------------------------------
// Card parsing (Slumbot uses ACPC format: "Ac", "Td", etc.)
// --------------------------------------------------------------------------

/// Parse a rank character to a rank index (0=Two, ..., 12=Ace).
fn parse_rank(c: u8) -> Option<u8> {
    match c {
        b'2' => Some(0),
        b'3' => Some(1),
        b'4' => Some(2),
        b'5' => Some(3),
        b'6' => Some(4),
        b'7' => Some(5),
        b'8' => Some(6),
        b'9' => Some(7),
        b'T' => Some(8),
        b'J' => Some(9),
        b'Q' => Some(10),
        b'K' => Some(11),
        b'A' => Some(12),
        _ => None,
    }
}

/// Parse a suit character to a suit index (0=Clubs, 1=Diamonds, 2=Hearts, 3=Spades).
fn parse_suit(c: u8) -> Option<u8> {
    match c {
        b'c' => Some(0),
        b'd' => Some(1),
        b'h' => Some(2),
        b's' => Some(3),
        _ => None,
    }
}

/// Parse a Slumbot card string (e.g., "Ac") to our Card representation.
pub fn parse_card_string(s: &str) -> Option<Card> {
    let bytes = s.as_bytes();
    if bytes.len() < 2 {
        return None;
    }
    let rank = parse_rank(bytes[0])?;
    let suit = parse_suit(bytes[1])?;
    Some(card::create(rank, suit))
}

/// Convert a Card to Slumbot string format (e.g., "Ac").
fn card_to_string(c: Card) -> String {
    let rank_char = match card::rank(c) {
        0 => '2',
        1 => '3',
        2 => '4',
        3 => '5',
        4 => '6',
        5 => '7',
        6 => '8',
        7 => '9',
        8 => 'T',
        9 => 'J',
        10 => 'Q',
        11 => 'K',
        12 => 'A',
        _ => '?',
    };
    let suit_char = match card::suit(c) {
        0 => 'c',
        1 => 'd',
        2 => 'h',
        3 => 's',
        _ => '?',
    };
    format!("{}{}", rank_char, suit_char)
}

// --------------------------------------------------------------------------
// Slumbot action string parsing
// --------------------------------------------------------------------------

/// Parsed state of a Slumbot action string.
#[derive(Debug, Clone)]
pub struct ActionState {
    pub street: i32,
    pub pos: i32,                // -1 = hand over
    pub street_last_bet_to: i32,
    pub total_last_bet_to: i32,
    pub last_bet_size: i32,
    pub last_bettor: i32,        // -1 = no bettor
}

/// Parse Slumbot's action string to determine game state.
///
/// Actions: k=check, c=call, f=fold, b{N}=bet to N chips on this street.
/// Streets separated by '/'.
pub fn parse_slumbot_action(action: &str) -> ActionState {
    let bytes = action.as_bytes();
    let sz = bytes.len();
    let mut st = 0i32;
    let mut street_last_bet_to = SLUMBOT_BIG_BLIND;
    let mut total_last_bet_to = SLUMBOT_BIG_BLIND;
    let mut last_bet_size = SLUMBOT_BIG_BLIND - SLUMBOT_SMALL_BLIND;
    let mut last_bettor = 0i32;
    let mut pos = 1i32; // SB acts first preflop
    let mut check_or_call_ends_street = false;
    let mut i = 0usize;

    while i < sz {
        let c = bytes[i];
        i += 1;
        match c {
            b'k' => {
                if check_or_call_ends_street {
                    // Consume optional '/' separator
                    if st < 3 && i < sz && bytes[i] == b'/' {
                        i += 1;
                    }
                    if st >= 3 {
                        pos = -1;
                    } else {
                        pos = 0;
                        st += 1;
                    }
                    street_last_bet_to = 0;
                    last_bet_size = 0;
                    last_bettor = -1;
                    check_or_call_ends_street = false;
                } else {
                    pos = (pos + 1) % 2;
                    check_or_call_ends_street = true;
                }
            }
            b'c' => {
                if total_last_bet_to == SLUMBOT_STACK {
                    // Call of all-in -- skip remaining street slashes
                    while i < sz {
                        if bytes[i] == b'/' {
                            i += 1;
                        } else {
                            i = sz;
                        }
                    }
                    st = 3;
                    pos = -1;
                    last_bet_size = 0;
                } else if check_or_call_ends_street {
                    // Consume optional '/' separator
                    if st < 3 && i < sz && bytes[i] == b'/' {
                        i += 1;
                    }
                    if st >= 3 {
                        pos = -1;
                    } else {
                        pos = 0;
                        st += 1;
                    }
                    street_last_bet_to = 0;
                    check_or_call_ends_street = false;
                    last_bet_size = 0;
                    last_bettor = -1;
                } else {
                    pos = (pos + 1) % 2;
                    check_or_call_ends_street = true;
                    last_bet_size = 0;
                    last_bettor = -1;
                }
            }
            b'f' => {
                pos = -1;
                i = sz; // fold ends hand
            }
            b'b' => {
                // Parse bet size
                let j = i;
                while i < sz && bytes[i] >= b'0' && bytes[i] <= b'9' {
                    i += 1;
                }
                if i > j {
                    let num_str = std::str::from_utf8(&bytes[j..i]).unwrap_or("0");
                    let new_street_bet: i32 = num_str.parse().unwrap_or(0);
                    let new_last_bet_size = new_street_bet - street_last_bet_to;
                    last_bet_size = new_last_bet_size;
                    street_last_bet_to = new_street_bet;
                    total_last_bet_to += new_last_bet_size;
                    last_bettor = pos;
                    pos = (pos + 1) % 2;
                    check_or_call_ends_street = true;
                }
            }
            b'/' => {
                // Explicit street separator (can appear in all-in runouts)
                st += 1;
                street_last_bet_to = 0;
                pos = 0;
                check_or_call_ends_street = false;
            }
            _ => {}
        }
    }

    ActionState {
        street: st,
        pos,
        street_last_bet_to,
        total_last_bet_to,
        last_bet_size,
        last_bettor,
    }
}

// --------------------------------------------------------------------------
// Convert Slumbot action history to internal NL history format
// --------------------------------------------------------------------------

/// Convert Slumbot action string to the internal history format used by
/// our MCCFR for info-set key construction.
///
/// Slumbot: k=check, c=call, f=fold, b{N}=bet/raise to N
/// Internal: k=check, c=call, f=fold, h/p/d/a=bet fractions
///
/// Since Slumbot's bet sizes are continuous and ours are bucketed
/// (0.5x, 1.0x, 2.0x pot), we map each Slumbot bet to the nearest
/// fraction category.
fn slumbot_action_to_internal_history(action: &str) -> Vec<u8> {
    let bytes = action.as_bytes();
    let sz = bytes.len();
    let mut buf = Vec::with_capacity(sz);
    let mut i = 0usize;
    let mut street_pot = SLUMBOT_SMALL_BLIND + SLUMBOT_BIG_BLIND;
    let mut street_invested = [SLUMBOT_SMALL_BLIND, SLUMBOT_BIG_BLIND];
    let mut cur_pos = 1usize; // SB acts first preflop

    while i < sz {
        let c = bytes[i];
        i += 1;
        match c {
            b'k' => {
                buf.push(b'k');
                cur_pos = (cur_pos + 1) % 2;
            }
            b'c' => {
                buf.push(b'c');
                let other = (cur_pos + 1) % 2;
                let to_call = street_invested[other] - street_invested[cur_pos];
                street_invested[cur_pos] += to_call;
                street_pot += to_call;
                cur_pos = (cur_pos + 1) % 2;
            }
            b'f' => {
                buf.push(b'f');
            }
            b'b' => {
                let j = i;
                while i < sz && bytes[i] >= b'0' && bytes[i] <= b'9' {
                    i += 1;
                }
                let num_str = std::str::from_utf8(&bytes[j..i]).unwrap_or("0");
                let new_street_bet: i32 = num_str.parse().unwrap_or(0);
                let raise_amount = new_street_bet - street_invested[cur_pos];
                let pot_before = street_pot;
                let frac = if pot_before > 0 {
                    raise_amount as f64 / pot_before as f64
                } else {
                    1.0
                };

                // Map to nearest fraction bucket or all-in
                let hist_char = if frac >= 1.5 {
                    if new_street_bet >= SLUMBOT_STACK {
                        b'a'
                    } else {
                        b'd' // 2x pot
                    }
                } else if frac >= 0.75 {
                    b'p' // 1x pot
                } else {
                    b'h' // 0.5x pot
                };

                buf.push(hist_char);
                street_invested[cur_pos] = new_street_bet;
                street_pot += raise_amount;
                cur_pos = (cur_pos + 1) % 2;
            }
            b'/' => {
                buf.push(b'/');
                street_invested[0] = 0;
                street_invested[1] = 0;
                cur_pos = 0; // Post-flop: position 0 (BB) acts first
            }
            _ => {}
        }
    }

    buf
}

// --------------------------------------------------------------------------
// Action selection using trained NL strategy
// --------------------------------------------------------------------------

/// Select an action for the current Slumbot game state.
///
/// Maps the Slumbot state to an internal info-set key, looks up the
/// strategy, samples an action, then converts back to Slumbot format.
///
/// Returns: (slumbot_action_string, internal_history_char, strategy_probs)
fn select_slumbot_action(
    p0_strat: &Strategy,
    p1_strat: &Strategy,
    hole_cards: &[Card; 2],
    board: &[Card],
    client_pos: i32,
    action: &str,
    action_state: &ActionState,
    n_buckets: u32,
    preflop_assignments: &[i32; 169],
    _config: &GameConfig,
    rng: &mut impl rand::Rng,
) -> (String, u64, Vec<f32>) {
    // Compute buckets for the current board state
    let board5 = board_to_array5(board);
    let buckets_arr = buckets::precompute_buckets(hole_cards, &board5, n_buckets, preflop_assignments);

    let round_idx = action_state.street as u8;
    let internal_history = slumbot_action_to_internal_history(action);
    let key = info_key::make_info_key(&buckets_arr, round_idx, &internal_history);

    // client_pos 0 (BB) -> use p1_strat, client_pos 1 (SB) -> use p0_strat
    let strategy = match client_pos {
        1 => p0_strat, // SB = position 0
        _ => p1_strat, // BB = position 1
    };

    // Available actions: fold (if facing bet), check/call, bet fractions, all-in
    let facing_bet = action_state.last_bet_size > 0;
    let mut actions: Vec<(String, u8)> = Vec::new();

    if facing_bet {
        actions.push(("f".to_string(), b'f'));
    }

    if facing_bet {
        actions.push(("c".to_string(), b'c'));
    } else {
        actions.push(("k".to_string(), b'k'));
    }

    // Add bet options: map internal fractions to Slumbot bet sizes
    let pot = action_state.total_last_bet_to * 2; // approximate
    let to_call = action_state.last_bet_size;
    let remaining = SLUMBOT_STACK - action_state.total_last_bet_to;
    let can_raise = remaining > to_call;

    if can_raise {
        for &(frac, hist_char) in &[(0.5, b'h'), (1.0, b'p'), (2.0, b'd')] {
            let pot_after_call = pot + to_call;
            let raise_amount = (pot_after_call as f64 * frac) as i32;
            let raise_amount = raise_amount.max(SLUMBOT_BIG_BLIND);
            let new_bet = action_state.street_last_bet_to + to_call + raise_amount;
            let max_bet = SLUMBOT_STACK - action_state.total_last_bet_to
                + action_state.street_last_bet_to;
            let new_bet = new_bet.min(max_bet);
            if new_bet > action_state.street_last_bet_to && new_bet < SLUMBOT_STACK {
                actions.push((format!("b{}", new_bet), hist_char));
            }
        }
        // All-in
        if remaining > 0 {
            let all_in_street_bet = action_state.street_last_bet_to + remaining;
            actions.push((format!("b{}", all_in_street_bet), b'a'));
        }
    }

    let num_actions = actions.len();

    // Look up strategy
    let probs = match strategy.get(&key) {
        Some(p) if p.len() == num_actions => p.clone(),
        _ => vec![1.0 / num_actions as f32; num_actions],
    };

    // Sample action from probability distribution
    let r: f32 = rng.gen();
    let mut cumulative = 0.0f32;
    let mut chosen_idx = num_actions - 1;
    for (i, &p) in probs.iter().enumerate() {
        cumulative += p;
        if cumulative >= r {
            chosen_idx = i;
            break;
        }
    }

    let (slumbot_action, _hist_char) = &actions[chosen_idx];
    (slumbot_action.clone(), key, probs)
}

/// Convert a board slice to a fixed [Card; 5] array, padding with 0.
fn board_to_array5(board: &[Card]) -> [Card; 5] {
    let mut arr = [0u8; 5];
    for (i, &c) in board.iter().enumerate().take(5) {
        arr[i] = c;
    }
    arr
}

// --------------------------------------------------------------------------
// HTTP client
// --------------------------------------------------------------------------

fn http_post(url: &str, body: &serde_json::Value) -> Result<Value, String> {
    let mut response = ureq::post(url)
        .header("Content-Type", "application/json")
        .send_json(body)
        .map_err(|e| format!("HTTP error: {}", e))?;

    let json: Value = response.body_mut().read_json()
        .map_err(|e| format!("JSON parse error: {}", e))?;

    // Check for API error
    if let Some(err_msg) = json.get("error_msg").and_then(|v| v.as_str()) {
        return Err(format!("Slumbot API error: {}", err_msg));
    }

    Ok(json)
}

fn slumbot_new_hand(token: Option<&str>) -> Result<Value, String> {
    let url = format!("{}/new_hand", SLUMBOT_BASE_URL);
    let body = match token {
        Some(t) => serde_json::json!({"token": t}),
        None => serde_json::json!({}),
    };
    http_post(&url, &body)
}

fn slumbot_act(token: &str, incr: &str) -> Result<Value, String> {
    let url = format!("{}/act", SLUMBOT_BASE_URL);
    let body = serde_json::json!({"token": token, "incr": incr});
    http_post(&url, &body)
}

// --------------------------------------------------------------------------
// JSON helpers
// --------------------------------------------------------------------------

fn json_str<'a>(json: &'a Value, field: &str) -> Option<&'a str> {
    json.get(field).and_then(|v| v.as_str())
}

fn json_int(json: &Value, field: &str) -> Option<i64> {
    json.get(field).and_then(|v| v.as_i64())
}

fn json_str_list<'a>(json: &'a Value, field: &str) -> Option<Vec<&'a str>> {
    json.get(field).and_then(|v| v.as_array()).map(|arr| {
        arr.iter().filter_map(|v| v.as_str()).collect()
    })
}

fn json_winnings(json: &Value) -> Option<i64> {
    match json.get("winnings") {
        Some(Value::Null) => None,
        Some(v) => v.as_i64(),
        None => None,
    }
}

// --------------------------------------------------------------------------
// Hand result
// --------------------------------------------------------------------------

/// Result of playing a single hand.
#[derive(Debug, Clone)]
pub struct HandResult {
    pub winnings: i32,
    pub client_pos: i32,
    pub hand_num: u32,
}

/// Result of a full session.
#[derive(Debug, Clone)]
pub struct SessionResult {
    pub hands_played: u32,
    pub total_winnings: i64,
    pub mean_bb: f64,
    pub stddev_bb: f64,
    pub ci_lo: f64,
    pub ci_hi: f64,
    pub significant: bool,
    pub elapsed_secs: f64,
}

// --------------------------------------------------------------------------
// Play config
// --------------------------------------------------------------------------

/// Configuration for playing against Slumbot.
pub struct PlayConfig {
    pub n_buckets: u32,
    pub preflop_assignments: [i32; 169],
    pub game_config: GameConfig,
    pub verbose: bool,
}

impl Default for PlayConfig {
    fn default() -> Self {
        let n_buckets = 169u32;
        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = ((i as u32 * n_buckets) / 169).min(n_buckets - 1) as i32;
        }
        Self {
            n_buckets,
            preflop_assignments: assignments,
            game_config: GameConfig::slumbot(),
            verbose: false,
        }
    }
}

// --------------------------------------------------------------------------
// Hand player
// --------------------------------------------------------------------------

/// Play a single hand against Slumbot.
///
/// Returns (new_token, HandResult).
pub fn play_hand(
    p0_strat: &Strategy,
    p1_strat: &Strategy,
    play_config: &PlayConfig,
    token: Option<&str>,
    hand_num: u32,
    rng: &mut impl rand::Rng,
) -> Result<(Option<String>, HandResult), String> {
    let json = slumbot_new_hand(token)?;

    let new_token = json_str(&json, "token").map(|s| s.to_string());
    let tok = new_token.as_deref()
        .or(token)
        .unwrap_or("")
        .to_string();

    let client_pos = json_int(&json, "client_pos").unwrap_or(0) as i32;

    let hole_cards_strs = json_str_list(&json, "hole_cards")
        .ok_or("play_hand: no hole_cards in response")?;
    if hole_cards_strs.len() != 2 {
        return Err(format!("play_hand: expected 2 hole cards, got {}", hole_cards_strs.len()));
    }
    let c1 = parse_card_string(hole_cards_strs[0])
        .ok_or_else(|| format!("bad card: {}", hole_cards_strs[0]))?;
    let c2 = parse_card_string(hole_cards_strs[1])
        .ok_or_else(|| format!("bad card: {}", hole_cards_strs[1]))?;
    let hole_cards = [c1, c2];

    if play_config.verbose {
        eprintln!("[slumbot] Hand {} started. pos={} hole={}{}",
            hand_num, client_pos, card_to_string(c1), card_to_string(c2));
    }

    // Play loop
    let mut current_json = json;
    loop {
        let action = json_str(&current_json, "action").unwrap_or("").to_string();

        let board_strs = json_str_list(&current_json, "board").unwrap_or_default();
        let board: Vec<Card> = board_strs.iter()
            .filter_map(|s| parse_card_string(s))
            .collect();

        // Check if hand is over
        if let Some(winnings) = json_winnings(&current_json) {
            let winnings = winnings as i32;
            if play_config.verbose {
                eprintln!("[slumbot] Hand {} over. action={} winnings={}",
                    hand_num, action, winnings);
            }
            return Ok((Some(tok), HandResult {
                winnings,
                client_pos,
                hand_num,
            }));
        }

        // Parse action state and check if it's our turn
        let a_state = parse_slumbot_action(&action);
        let our_turn = a_state.pos >= 0 && a_state.pos == client_pos;

        if !our_turn {
            if play_config.verbose {
                eprintln!("[slumbot] Not our turn. action={}", action);
            }
            return Ok((Some(tok), HandResult {
                winnings: 0,
                client_pos,
                hand_num,
            }));
        }

        // Select and send action
        let (incr, key, probs) = select_slumbot_action(
            p0_strat,
            p1_strat,
            &hole_cards,
            &board,
            client_pos,
            &action,
            &a_state,
            play_config.n_buckets,
            &play_config.preflop_assignments,
            &play_config.game_config,
            rng,
        );

        if play_config.verbose {
            let probs_str: Vec<String> = probs.iter().map(|p| format!("{:.3}", p)).collect();
            eprintln!("[slumbot] action={} our_incr={} key={} probs=[{}]",
                action, incr, key, probs_str.join(","));
        }

        current_json = slumbot_act(&tok, &incr)?;
    }
}

// --------------------------------------------------------------------------
// Session runner
// --------------------------------------------------------------------------

/// Play N hands against Slumbot and print statistics.
pub fn run_session(
    p0_strat: &Strategy,
    p1_strat: &Strategy,
    play_config: &PlayConfig,
    num_hands: u32,
) -> Result<SessionResult, String> {
    use std::time::Instant;

    eprintln!("[slumbot] Starting session: LIVE (slumbot.com), {} hands", num_hands);
    eprintln!("[slumbot] Strategy: P0={} P1={} info sets",
        p0_strat.len(), p1_strat.len());

    let mut rng = rand::thread_rng();
    let mut token: Option<String> = None;
    let mut total_winnings: i64 = 0;
    let mut hand_results: Vec<f64> = Vec::with_capacity(num_hands as usize);
    let start = Instant::now();

    for hand in 1..=num_hands {
        match play_hand(
            p0_strat,
            p1_strat,
            play_config,
            token.as_deref(),
            hand,
            &mut rng,
        ) {
            Ok((new_token, result)) => {
                token = new_token;
                total_winnings += result.winnings as i64;
                hand_results.push(result.winnings as f64);

                let avg_bb = total_winnings as f64 / hand as f64 / SLUMBOT_BIG_BLIND as f64;
                if hand % 10 == 0 || play_config.verbose {
                    eprintln!("[slumbot] Hand {}/{}: won={} total={} ({:.2} mbb/hand)",
                        hand, num_hands, result.winnings, total_winnings, avg_bb * 1000.0);
                }
            }
            Err(e) => {
                eprintln!("[slumbot] Error on hand {}: {}", hand, e);
                // Reset token on error to start fresh
                token = None;
            }
        }
    }

    let elapsed = start.elapsed().as_secs_f64();
    let n = hand_results.len();
    let n_f = n as f64;
    let bb = SLUMBOT_BIG_BLIND as f64;

    // Convert per-hand chip winnings to bb/hand
    let winnings_bb: Vec<f64> = hand_results.iter().map(|w| w / bb).collect();

    let mean_bb = if n > 0 {
        winnings_bb.iter().sum::<f64>() / n_f
    } else {
        0.0
    };

    let variance = if n > 1 {
        let sum_sq_dev: f64 = winnings_bb.iter()
            .map(|w| { let d = w - mean_bb; d * d })
            .sum();
        sum_sq_dev / (n_f - 1.0)
    } else {
        0.0
    };

    let stddev = variance.sqrt();
    let se = if n > 0 { stddev / n_f.sqrt() } else { 0.0 };
    let ci_lo = mean_bb - 1.96 * se;
    let ci_hi = mean_bb + 1.96 * se;
    let significant = ci_lo > 0.0 || ci_hi < 0.0;

    // Minimum hands needed for +/-0.5 bb/hand CI at current stddev
    let hands_for_half_bb = if stddev > 0.0 {
        let z_sigma = 1.96 * stddev / 0.5;
        (z_sigma * z_sigma).ceil() as u64
    } else {
        0
    };

    // Print results
    println!();
    println!("================================================================");
    println!("  Slumbot Session Results (LIVE)");
    println!("================================================================");
    println!();
    println!("  Hands played:    {}", n);
    println!("  Total winnings:  {} chips", total_winnings);
    println!("  Average:         {:.2} mbb/hand", mean_bb * 1000.0);
    println!("  Average:         {:.4} bb/hand", mean_bb);
    println!("  Std dev:         {:.2} bb/hand", stddev);
    println!("  Std error:       {:.2} bb/hand", se);
    println!("  95% CI:          [{:.2}, {:.2}] bb/hand", ci_lo, ci_hi);
    if significant {
        println!("  Significant:     YES (CI excludes zero)");
    } else {
        println!("  Significant:     NO (CI includes zero)");
    }
    println!("  For +/-0.5 bb/hand CI: need {} hands", hands_for_half_bb);
    println!();
    println!("  Time:            {:.1} seconds ({:.2} hands/sec)", elapsed, n as f64 / elapsed);
    println!("  Game: HUNL 50/100 blinds, 20000 stack (200bb)");
    println!("  Strategy: NL MCCFR, P0={} P1={} info sets",
        p0_strat.len(), p1_strat.len());
    println!("================================================================");

    Ok(SessionResult {
        hands_played: n as u32,
        total_winnings,
        mean_bb,
        stddev_bb: stddev,
        ci_lo,
        ci_hi,
        significant,
        elapsed_secs: elapsed,
    })
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_card_string() {
        let c = parse_card_string("Ac").unwrap();
        assert_eq!(card::rank(c), 12); // Ace
        assert_eq!(card::suit(c), 0);  // Clubs

        let c = parse_card_string("Td").unwrap();
        assert_eq!(card::rank(c), 8);  // Ten
        assert_eq!(card::suit(c), 1);  // Diamonds

        let c = parse_card_string("2s").unwrap();
        assert_eq!(card::rank(c), 0);  // Two
        assert_eq!(card::suit(c), 3);  // Spades

        let c = parse_card_string("Kh").unwrap();
        assert_eq!(card::rank(c), 11); // King
        assert_eq!(card::suit(c), 2);  // Hearts

        assert!(parse_card_string("").is_none());
        assert!(parse_card_string("X").is_none());
        assert!(parse_card_string("Ax").is_none());
    }

    #[test]
    fn test_card_to_string() {
        assert_eq!(card_to_string(card::create(12, 0)), "Ac");
        assert_eq!(card_to_string(card::create(8, 1)), "Td");
        assert_eq!(card_to_string(card::create(0, 3)), "2s");
        assert_eq!(card_to_string(card::create(11, 2)), "Kh");
    }

    #[test]
    fn test_card_roundtrip_all() {
        for rank in 0..13u8 {
            for suit in 0..4u8 {
                let c = card::create(rank, suit);
                let s = card_to_string(c);
                let c2 = parse_card_string(&s).unwrap();
                assert_eq!(c, c2, "roundtrip failed for card {}", s);
            }
        }
    }

    #[test]
    fn test_parse_slumbot_action_empty() {
        let state = parse_slumbot_action("");
        assert_eq!(state.street, 0);
        assert_eq!(state.pos, 1); // SB acts first preflop
    }

    #[test]
    fn test_parse_slumbot_action_preflop_call() {
        // SB calls, BB checks => end of preflop
        let state = parse_slumbot_action("c");
        // After SB calls: check_or_call_ends_street=true, pos switches to 0
        assert_eq!(state.pos, 0);
    }

    #[test]
    fn test_parse_slumbot_action_fold() {
        let state = parse_slumbot_action("f");
        assert_eq!(state.pos, -1); // hand over
    }

    #[test]
    fn test_parse_slumbot_action_bet() {
        let state = parse_slumbot_action("b200");
        // SB bets to 200
        assert_eq!(state.street_last_bet_to, 200);
        assert_eq!(state.pos, 0); // BB to act
    }

    #[test]
    fn test_parse_slumbot_action_streets() {
        // Preflop: SB calls, BB checks -> flop
        // cc: SB call, then BB check ends street
        let state = parse_slumbot_action("cc/");
        assert_eq!(state.street, 1);
        assert_eq!(state.pos, 0); // post-flop BB acts first
    }

    #[test]
    fn test_slumbot_action_to_internal_history() {
        let hist = slumbot_action_to_internal_history("cc");
        assert_eq!(hist, b"cc");

        let hist = slumbot_action_to_internal_history("f");
        assert_eq!(hist, b"f");

        let hist = slumbot_action_to_internal_history("cc/kk");
        assert_eq!(hist, b"cc/kk");
    }

    #[test]
    fn test_slumbot_action_to_internal_history_bet() {
        // b200: SB puts 200 on street.
        // cur_pos=1 (SB), street_invested[1]=100 (BB init), raise_amount=200-100=100
        // pot_before = 150, frac = 100/150 = 0.667 -> h (half pot, frac < 0.75)
        let hist = slumbot_action_to_internal_history("b200");
        assert_eq!(hist, b"h");

        // A pot-sized raise: SB raises to 300.
        // raise_amount = 300 - 100 = 200, pot = 150, frac = 200/150 = 1.33 -> p (>= 0.75)
        let hist = slumbot_action_to_internal_history("b300");
        assert_eq!(hist, b"p");

        // A big bet: SB raises to 500.
        // raise_amount = 500 - 100 = 400, pot = 150, frac = 400/150 = 2.67 -> d (>= 1.5)
        let hist = slumbot_action_to_internal_history("b500");
        assert_eq!(hist, b"d");
    }

    #[test]
    fn test_action_state_check_check_all_streets() {
        // Full check-down: cc/kk/kk/kk
        let state = parse_slumbot_action("cc/kk/kk/kk");
        assert_eq!(state.street, 3);
        assert_eq!(state.pos, -1); // river check-check ends the hand
    }

    #[test]
    fn test_play_config_default() {
        let config = PlayConfig::default();
        assert_eq!(config.n_buckets, 169);
        assert_eq!(config.game_config.small_blind, 50);
        assert_eq!(config.game_config.big_blind, 100);
    }

    #[test]
    fn test_board_to_array5() {
        let board = vec![1u8, 2, 3];
        let arr = board_to_array5(&board);
        assert_eq!(arr, [1, 2, 3, 0, 0]);

        let board = vec![10u8, 20, 30, 40, 50];
        let arr = board_to_array5(&board);
        assert_eq!(arr, [10, 20, 30, 40, 50]);
    }

    #[test]
    fn test_load_strategy_empty_path() {
        // Loading from a non-existent file should error
        let result = load_strategy(Path::new("/nonexistent/strategy.bin"));
        assert!(result.is_err());
    }
}
