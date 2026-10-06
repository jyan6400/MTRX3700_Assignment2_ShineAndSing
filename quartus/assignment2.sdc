# ============================================================
# Assignment 2 timing constraints
# ============================================================

# 50 MHz board/system clock
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# Audio codec bit clock: 3.072 MHz
create_clock -name AUD_BCLK -period 325.521 [get_ports {AUD_BCLK}]

# Derive PLL-generated clocks
derive_pll_clocks

# Add clock uncertainty after all clocks are known
derive_clock_uncertainty


# ============================================================
# Intentional CDC paths
# ============================================================

# ------------------------------------------------------------
# 18.432 MHz audio PLL -> 50 MHz game/system domain
# audio_game_cdc first-stage synchronizers
# ------------------------------------------------------------

set_false_path -to [get_registers {*u_audio_game_cdc|req_sync_1}]
set_false_path -to [get_registers {*u_audio_game_cdc|vowel_sync_1[*]}]

# 50 MHz -> audio-side acknowledgement first synchronizer stage
set_false_path -to [get_registers {*u_audio_game_cdc|ack_sync_1}]


# ------------------------------------------------------------
# Audio-domain status/debug signals -> 50 MHz display/debug logic
# These are first-stage sampling registers only.
# ------------------------------------------------------------

set_false_path -to [get_registers {*peak_meta[*]}]
set_false_path -to [get_registers {*db_meta[*]}]
set_false_path -to [get_registers {*class_meta[*]}]
set_false_path -to [get_registers {*voice_meta}]
set_false_path -to [get_registers {*reject_meta}]


# ------------------------------------------------------------
# AUD_BCLK -> 18.432 MHz audio feature domain
# voice_active CDC first-stage synchronizer
# ------------------------------------------------------------

set_false_path -to [get_registers {*u_audio_features|va_meta}]