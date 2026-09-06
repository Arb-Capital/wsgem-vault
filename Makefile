# WsgemVault (ERC-4626 vault over a wsgem token) — dev tasks.

# Optional .env (gitignored; see .env.example). RPC precedence everywhere:
# explicit ETH_RPC_URL > ALCHEMY_API_KEY-composed Alchemy endpoint > public fallback.
# The fork suites resolve the same chain themselves (ForkBase), so direct `forge test`
# runs get it too; exporting here covers every make-invoked child process.
-include .env
ifndef ETH_RPC_URL
ifdef ALCHEMY_API_KEY
ETH_RPC_URL := https://eth-mainnet.g.alchemy.com/v2/$(ALCHEMY_API_KEY)
endif
endif
ifdef ETH_RPC_URL
export ETH_RPC_URL
endif
ifdef ALCHEMY_API_KEY
export ALCHEMY_API_KEY
endif
ifdef FORK_BLOCK
export FORK_BLOCK
endif

# Which deploy script the deploy/check targets drive. Defaults to the pinned wstGBP
# instance, which needs no configuration at all. For any other wsgem, point SCRIPT at the
# generic pattern script and supply WSGEM + EXPECTED_GEM + VAULT_NAME + VAULT_SYMBOL:
#   make deploy-dry SCRIPT=script/DeployWsgemVault.s.sol
SCRIPT ?= script/DeployWstGbpVault.s.sol

# Deploy/check configuration read by the generic script via vm.env* (see the script
# header). The pinned wstGBP script reads none of them and refuses any that contradict its
# pinned values. Exported only when defined: a bare `export VAR` would hand the child an
# EMPTY string, which vm.envOr treats as set-but-malformed and aborts on.
ifdef WSGEM
export WSGEM
endif
ifdef EXPECTED_GEM
export EXPECTED_GEM
endif
ifdef VAULT_NAME
export VAULT_NAME
endif
ifdef VAULT_SYMBOL
export VAULT_SYMBOL
endif
ifdef ETHERSCAN_API_KEY
export ETHERSCAN_API_KEY
endif

# Keyless forge-script invocations (dry runs, health checks) must strip EVERY wallet-resolving
# env var a previous deploy session may have left exported — forge binds ETH_FROM/--sender,
# ETH_KEYSTORE/--keystore, ETH_KEYSTORE_ACCOUNT/--account, ETH_PASSWORD/--password, and clap
# couples them (a stray ETH_PASSWORD with the keystore stripped fails argument parsing outright).
KEYLESS := env -u ETH_FROM -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD

# Offline invocations strip the RPC vars so `make test` / `make coverage` stay deterministic
# (fork/smoke suites skip) even when .env configures an RPC.
OFFLINE := env -u ETH_RPC_URL -u ALCHEMY_API_KEY

PUBLIC_RPC := https://ethereum-rpc.publicnode.com

# Excluded from the coverage report: the test suite and the deploy script. Leaves only
# the first-party audited surface (src/).
COVERAGE_EXCLUDE := (test/|script/)

.PHONY: build test test-fork test-smoke test-all fmt clean coverage gen-report serve-report \
	deploy deploy-dry verify check

build :; forge build

# Offline dev/CI loop: unit + fuzz + ERC-4626 property + invariant + deploy-script + decimals
# suites. Deterministic — the fork/smoke suites skip even when .env configures an RPC.
test :; @$(OFFLINE) forge test -vvv

# Deterministic pinned-block fork suites (vault behaviour against live wstGBP, plus the
# pinned wstGBP deploy script). Needs an archive-capable RPC (any Alchemy/Infura endpoint;
# the public fallback often 403s archive requests). FORK_BLOCK overrides the pin.
test-fork :; REQUIRE_FORK=true forge test -vvv --match-contract 'ForkTest$$'

# Latest-block live-parameter smoke checks: a failure means live wsgem config or gem
# liquidity moved (fees, cooldown, market windows, compliance), not a code regression.
test-smoke :; REQUIRE_FORK=true forge test -vvv --match-contract 'SmokeTest$$'

# Everything the configured RPC allows; offline it degrades to `make test` (fork/smoke skip).
test-all :; forge test -vvv

fmt :; forge fmt

clean :; forge clean

# Summary coverage to the terminal, over the offline suites (deterministic). Forge
# disables optimizer/viaIR here for more accurate source maps.
coverage :; @$(OFFLINE) forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)"

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info.
gen-report :; @$(OFFLINE) forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the HTML report at http://localhost:8000 — opening index.html directly in a
# Flatpak/Snap browser routes through the document portal, which only shares that one
# file with the sandbox and so drops the report's CSS/images. HTTP avoids that.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report

# Simulate the full deploy against live mainnet state — no broadcast, no key, nothing sent.
# Exercises config resolution, the pre-deploy asserts, and the whole post-deploy sanity
# battery, and writes the planned tx to broadcast/<script>/1/dry-run/. Drives the pinned
# wstGBP script; see SCRIPT above for any other instance. Falls back to the public RPC when
# ETH_RPC_URL is unset. Pass SENDER=0x... (the deployer address; no key needed to simulate
# from it) so the predicted address and nonce are the real ones rather than forge's default.
deploy-dry :; @$(KEYLESS) forge script $(SCRIPT) --rpc-url $(or $(ETH_RPC_URL),$(PUBLIC_RPC)) $(if $(SENDER),--sender $(SENDER)) -vvv

# Mainnet deploy: deploys the vault, runs the sanity battery, and verifies on Etherscan
# inline. Signs from an encrypted keystore (`--keystore` + `--sender`) — forge prompts for
# the keystore password; no raw private key on the command line or in the environment.
# Requires: ETH_RPC_URL, ETH_FROM (deployer address), ETH_KEYSTORE (keystore JSON path),
# ETHERSCAN_API_KEY. Optional: ETH_PRIO_FEE → --priority-gas-price and ETH_GAS_PRICE →
# --with-gas-price; when unset, forge auto-estimates. Run `make deploy-dry` first.
deploy :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
	forge script $(SCRIPT) --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
		$(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE)) \
		--broadcast --slow --verify --etherscan-api-key $(ETHERSCAN_API_KEY)

# Verify an explicit mined address, with constructor arguments extracted from its on-chain
# creation code. No signing wallet or transaction-submitting script is involved. For the
# mainnet default the RPC's chain id is checked first: the constructor arguments are read
# from the RPC but submitted to the CHAIN explorer, so a testnet ETH_RPC_URL left in .env
# would otherwise feed the wrong chain's creation code to the mainnet explorer.
# Usage: make verify VAULT=0x... (CHAIN defaults to mainnet for the pinned instance).
CHAIN ?= mainnet
VERIFY_RPC := $(or $(ETH_RPC_URL),$(PUBLIC_RPC))
verify :
	@test -n "$(VAULT)" || { echo "VAULT (deployed address) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required"; exit 1; }
	@[ "$(CHAIN)" != mainnet ] || [ "$$(cast chain-id --rpc-url "$(VERIFY_RPC)")" = 1 ] \
		|| { echo "RPC is not Ethereum mainnet (chain id 1); refusing to read constructor args from it"; exit 1; }
	@$(KEYLESS) forge verify-contract "$(VAULT)" src/WsgemVault.sol:WsgemVault \
		--chain "$(CHAIN)" --rpc-url "$(VERIFY_RPC)" \
		--guess-constructor-args --watch

# Post-broadcast / any-time health check against a live vault (view-only, keyless): the full
# sanity battery — bindings, rate, previews, max*, deficit()==0, and which legs are open.
# Expectations come from the script's own target() — pinned for wstGBP, WSGEM / EXPECTED_GEM
# for the generic script — never from the vault under check.
# Usage: make check VAULT=0x...
check :
	@test -n "$(VAULT)" || { echo "VAULT (deployed WsgemVault address) is required, e.g. make check VAULT=0x..."; exit 1; }
	@$(KEYLESS) forge script $(SCRIPT) --sig "check(address)" $(VAULT) --rpc-url $(or $(ETH_RPC_URL),$(PUBLIC_RPC)) -vvv
