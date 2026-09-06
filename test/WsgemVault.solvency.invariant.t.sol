// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerGate} from "maseer-one/MaseerGate.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {MockGem} from "./mocks/MockGem.sol";
import {InvariantBase} from "./InvariantBase.sol";

/// @dev Two campaigns for the two solvency questions WsgemVault.invariant.t.sol does not
/// ask: can any sequence of vault legs extract value through rounding, and can any user
/// action lower the wsgem backing of the shares that remain. Same house rules as that
/// file: `fail_on_revert = false`, so every handler op keeps a liveness counter, violations
/// are counted inside the handler rather than asserted, and a deterministic
/// `test_HandlerWiring_*` proves every op reachable. Each campaign also runs over a
/// 6-decimal gem and checks the view facts shared by every campaign (InvariantBase).
///
/// Seeds decode roles from their low 64 bits (payer/owner `% 3`, receiver `/ 3 % 3`,
/// operator `/ 9 % 3`, via-operator `/ 27 % 2`); the rounding campaign reads an
/// amount-shaping mode from bit 64 up. `roles` builds such a seed for the wiring tests.
function roles(uint256 payer, uint256 receiver, uint256 operator, bool viaOperator, uint256 mode)
    pure
    returns (uint256)
{
    return payer + 3 * receiver + 9 * operator + (viaOperator ? 27 : 0) + (mode << 64);
}

/// @notice Three actors, seed-decoded roles, and revert-tolerant vault calls shared by both
/// handlers.
abstract contract ActorHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MASK = type(uint64).max;

    WsgemVault internal vault;
    Wsgem internal wsgem;
    MockGem internal gem;
    uint256 internal scale; // one whole gem in native units
    address[3] internal actors;

    uint256 public operatorOk; // an owner != caller flow ran through the allowance path

    constructor(WsgemVault _vault, Wsgem _wsgem, MockGem _gem, string memory tag) {
        vault = _vault;
        wsgem = _wsgem;
        gem = _gem;
        scale = 10 ** _gem.decimals();
        actors =
            [makeAddr(string.concat(tag, "0")), makeAddr(string.concat(tag, "1")), makeAddr(string.concat(tag, "2"))];
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i % 3];
    }

    function _payer(uint256 seed) internal view returns (address) {
        return actors[(seed & MASK) % 3];
    }

    function _receiver(uint256 seed) internal view returns (address) {
        return actors[((seed & MASK) / 3) % 3];
    }

    function _operator(uint256 seed) internal view returns (address) {
        return actors[((seed & MASK) / 9) % 3];
    }

    function _viaOperator(uint256 seed) internal pure returns (bool) {
        return ((seed & MASK) / 27) % 2 == 1;
    }

    function _gemMax() internal view returns (uint256) {
        return 1e6 * scale;
    }

    /// @dev Low-level vault call as `caller`: a revert is an outcome, never a handler crash.
    function _call(address caller, bytes memory data) internal returns (bool ok, uint256 got) {
        vm.prank(caller);
        bytes memory ret;
        (ok, ret) = address(vault).call(data);
        if (ok) got = abi.decode(ret, (uint256));
    }

    /// @dev Runs `data` as `owner`, or as an operator approved for exactly `shares` when
    /// the seed says so.
    function _exec(uint256 seed, address owner, uint256 shares, bytes memory data)
        internal
        returns (bool ok, uint256 got)
    {
        address caller = owner;
        if (_viaOperator(seed) && _operator(seed) != owner) {
            caller = _operator(seed);
            vm.prank(owner);
            vault.approve(caller, shares);
            operatorOk++;
        }
        return _call(caller, data);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

/*//////////////////////////////////////////////////////////////
                        ROUNDING LEDGER
//////////////////////////////////////////////////////////////*/

/// @notice Healthy market with a live oracle, fees anywhere from zero to 3% each way (so
/// mintcost and burncost usually differ from navprice and from each other, and sometimes
/// coincide), and a NAV that accrues upward over time with the yield arriving in the
/// wsgem's pool as gem, or marks down with nothing moving. Every gem minted to an actor is credited to its `basis`; every leg
/// moves basis between payer/owner and receiver at the INPUT value, so what a conversion
/// costs its receiver shows up as basis exceeding value. `modelLoss` accrues that cost as an
/// independent reference model computes it from the wsgem's own mintcost/burncost/navprice
/// and the documented rounding (gem in and wsgem out floor, the gem claim floors, the
/// shares needed ceil), so the ledger must match to the wei in both directions. Units are
/// gem-wei scaled by 1e18. `ghostShares` follows the modeled share movements through the
/// legs alone, so a NAV move that touched a balance would break it. Bookkeeping uses
/// expected amounts: a bad return or missing backing must not panic and erase a breach.
contract RoundingLedgerHandler is ActorHandler {
    MaseerPrice internal pip;
    MaseerGate internal act;

    // Ghosts (never re-read from the contracts under test).
    mapping(address => int256) public basis; // entitlement, scaled; signed so a breach cannot underflow-revert
    mapping(address => uint256) public modelLoss; // what the reference model says the actor paid in fees and rounding
    mapping(address => uint256) public ghostShares; // share balance as moved by the legs
    uint256 public ghostNav;
    uint256 public ghostMintExcess;
    uint256 public ghostGemDust;
    uint256 public ghostDonated;
    uint256 public ghostGemDonated;
    uint256 internal navFloor; // markdowns never take the NAV below half its initial value

    // Violation counters.
    uint256 public legReverted; // a leg bounded to succeed reverted
    uint256 public modelMismatch; // a leg returned something other than the reference model
    uint256 public residueExceeded;
    uint256 public surplusExceeded;
    uint256 public sharesMovedOnAccrue;
    uint256 public bystanderMoved; // a lap moved another actor's position or quotes

    // Op liveness counters.
    uint256 public depositOk;
    uint256 public mintOk;
    uint256 public depositWsgemOk;
    uint256 public redeemOk;
    uint256 public withdrawOk;
    uint256 public redeemWsgemOk;
    uint256 public transferOk;
    uint256 public donateOk;
    uint256 public accrueOk;
    uint256 public setFeesOk;
    uint256 public roundTripOk;
    uint256 public markdownOk;
    uint256 public donateGemOk;

    constructor(WsgemVault _vault, Wsgem _wsgem, MockGem _gem, MaseerPrice _pip, MaseerGate _act)
        ActorHandler(_vault, _wsgem, _gem, "r")
    {
        pip = _pip;
        act = _act;
        ghostNav = wsgem.navprice();
        navFloor = ghostNav / 2;
    }

    /*//////////////////////// ledger ////////////////////////////*/

    function _fund(address a, uint256 gemAmt) internal {
        gem.mint(a, gemAmt);
        basis[a] += SafeCast.toInt256(gemAmt * WAD);
    }

    function _move(address from, address to, uint256 value) internal {
        basis[from] -= SafeCast.toInt256(value);
        basis[to] += SafeCast.toInt256(value);
    }

    /// @dev Direct wsgem mint to `u` against fresh gem: the wsgem floors at mintcost, and
    /// that cost lands on `u`.
    function _mintWsgemTo(address u, uint256 gemIn) internal returns (uint256 out) {
        uint256 expected = gemIn * WAD / wsgem.mintcost();
        _fund(u, gemIn);
        vm.startPrank(u);
        gem.approve(address(wsgem), gemIn);
        out = wsgem.mint(gemIn);
        vm.stopPrank();
        if (out != expected) modelMismatch++;
        modelLoss[u] += gemIn * WAD - expected * ghostNav;
    }

    /// @dev Books the gem a withdraw leaves behind per the model (`claim - assets`) against
    /// the README bound of `ceil(burncost / 1e18) - 1` per call.
    function _residue(uint256 needed, uint256 bc, uint256 assets) internal {
        uint256 residue = needed * bc / WAD - assets; // the ceil on `needed` makes the claim cover `assets`
        ghostGemDust += residue;
        if (residue > _ceilDiv(bc, WAD) - 1) residueExceeded++;
    }

    /// @dev Books the wsgem a mint leaves beyond its shares per the model (`floor(assets /
    /// mintcost) - shares`) against the README bound of less than one gem wei's worth of
    /// wsgem, `ceil(1e18 / mintcost) - 1` per call.
    function _surplus(uint256 assets, uint256 unit, uint256 shares) internal {
        uint256 excess = assets * WAD / unit - shares;
        ghostMintExcess += excess;
        if (excess > _ceilDiv(WAD, unit) - 1) surplusExceeded++;
    }

    struct Bystander {
        address who;
        uint256 bal;
        uint256 assets;
        uint256 claim;
        uint256 release;
        uint256 maxW;
    }

    function _snapOthers(address a) internal view returns (Bystander[2] memory others) {
        uint256 n;
        for (uint256 i = 0; i < 3; i++) {
            address b = actors[i];
            if (b == a) continue;
            uint256 bal = vault.balanceOf(b);
            others[n++] = Bystander({
                who: b,
                bal: bal,
                assets: vault.convertToAssets(bal),
                claim: vault.previewRedeem(bal),
                release: vault.previewRedeemToWsgem(bal),
                maxW: vault.maxWithdraw(b)
            });
        }
    }

    /// @dev README: a lap leaves every other holder's balance, `convertToAssets`,
    /// `previewRedeem` and `maxWithdraw` unchanged. A lap can only add gem to the wsgem's
    /// pool (the exit claims at most what the entry paid), so a liquidity-capped
    /// `maxWithdraw` may rise; an uncapped one (equal to the full claim) must not move.
    function _checkOthers(Bystander[2] memory others) internal {
        for (uint256 i = 0; i < 2; i++) {
            Bystander memory o = others[i];
            if (
                vault.balanceOf(o.who) != o.bal || vault.convertToAssets(o.bal) != o.assets
                    || vault.previewRedeem(o.bal) != o.claim || vault.previewRedeemToWsgem(o.bal) != o.release
            ) bystanderMoved++;
            uint256 maxW = vault.maxWithdraw(o.who);
            if (o.maxW == o.claim ? maxW != o.maxW : maxW < o.maxW) bystanderMoved++;
        }
    }

    /// @dev An amount in [lo, hi] shaped by the seed's mode: on a `unit` boundary, one
    /// wei either side of one, a few units, or anywhere in range.
    function _pick(uint256 seed, uint256 raw, uint256 unit, uint256 lo, uint256 hi) internal pure returns (uint256 v) {
        uint256 mode = (seed >> 64) % 8;
        uint256 k = bound(raw, 1, 1000);
        if (mode == 0) v = unit;
        else if (mode == 1) v = unit + 1;
        else if (mode == 2) v = k * unit - 1;
        else if (mode == 3) v = k * unit + 1;
        else if (mode == 4) v = bound(raw, lo, lo + 3 * unit);
        else v = bound(raw, lo, hi);
        if (v < lo) v = lo;
        if (v > hi) v = hi;
    }

    /*//////////////////////// vault legs ////////////////////////*/

    /// @dev Model: `wsgem.mint` issues floor(assets / mintcost) wsgem, one share each.
    function deposit(uint256 seed, uint256 raw) external {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 mc = wsgem.mintcost();
        uint256 assets = _pick(seed, raw, mc, mc, _gemMax());
        uint256 expected = assets * WAD / mc;
        _fund(a, assets);
        vm.prank(a);
        gem.approve(address(vault), assets);
        (bool ok, uint256 shares) = _call(a, abi.encodeCall(vault.deposit, (assets, r)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (shares != expected) modelMismatch++;
        _move(a, r, assets * WAD);
        ghostShares[r] += expected;
        modelLoss[r] += assets * WAD - expected * ghostNav;
        depositOk++;
    }

    /// @dev Model: the gem needed is ceil(shares * mintcost); wsgem minted beyond `shares`
    /// stays in the vault.
    function mint(uint256 seed, uint256 raw) external {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 shares = _pick(seed, raw, WAD, WAD, 1e24);
        uint256 unit = wsgem.mintcost();
        uint256 expected = _ceilDiv(shares * unit, WAD);
        _fund(a, expected);
        vm.prank(a);
        gem.approve(address(vault), expected);
        (bool ok, uint256 assets) = _call(a, abi.encodeCall(vault.mint, (shares, r)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (assets != expected) modelMismatch++;
        // Model surplus independently; an observed backing shortfall belongs in the
        // holdings invariant, never in a subtraction that can revert this handler.
        _surplus(expected, unit, shares);
        _move(a, r, expected * WAD);
        ghostShares[r] += shares;
        modelLoss[r] += expected * WAD - shares * ghostNav;
        mintOk++;
    }

    /// @dev Model: one share per wsgem, no fee, no rounding.
    function depositWsgem(uint256 seed, uint256 raw) external {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 mc = wsgem.mintcost();
        uint256 out = _mintWsgemTo(a, _pick(seed, raw, mc, mc, _gemMax()));
        vm.prank(a);
        wsgem.approve(address(vault), out);
        (bool ok, uint256 shares) = _call(a, abi.encodeCall(vault.depositWsgem, (out, r)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (shares != out) modelMismatch++;
        _move(a, r, out * ghostNav);
        ghostShares[r] += out;
        depositWsgemOk++;
    }

    /// @dev Model: `wsgem.redeem` pays floor(shares * burncost).
    function redeem(uint256 seed, uint256 raw) external {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 max = vault.maxRedeem(o);
        if (max < WAD) return;
        uint256 shares = _pick(seed, raw, WAD, WAD, max);
        uint256 expected = shares * wsgem.burncost() / WAD;
        (bool ok, uint256 assets) = _exec(seed, o, shares, abi.encodeCall(vault.redeem, (shares, r, o)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (assets != expected) modelMismatch++;
        _move(o, r, shares * ghostNav);
        ghostShares[o] -= shares;
        modelLoss[r] += shares * ghostNav - expected * WAD;
        redeemOk++;
    }

    /// @dev Model: the shares burned are ceil(assets / burncost); the claim their wsgem
    /// fetches covers `assets` and the rest stays in the vault as gem.
    function withdraw(uint256 seed, uint256 raw) external {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 bc = wsgem.burncost();
        uint256 max = vault.maxWithdraw(o);
        if (max < bc) return;
        uint256 assets = _pick(seed, raw, bc, bc, max);
        uint256 expected = _ceilDiv(assets * WAD, bc);
        (bool ok, uint256 shares) = _exec(seed, o, expected, abi.encodeCall(vault.withdraw, (assets, r, o)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (shares != expected) modelMismatch++;
        _move(o, r, expected * ghostNav);
        ghostShares[o] -= expected;
        modelLoss[r] += expected * ghostNav - assets * WAD;
        _residue(expected, bc, assets);
        withdrawOk++;
    }

    /// @dev Model: one wsgem per share, no fee, no rounding.
    function redeemToWsgem(uint256 seed, uint256 raw) external {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(o);
        if (bal == 0) return;
        uint256 shares = _pick(seed, raw, WAD, 1, bal);
        (bool ok, uint256 out) = _exec(seed, o, shares, abi.encodeCall(vault.redeemToWsgem, (shares, r, o)));
        if (!ok) {
            legReverted++;
            return;
        }
        if (out != shares) modelMismatch++;
        _move(o, r, shares * ghostNav);
        ghostShares[o] -= shares;
        redeemWsgemOk++;
    }

    function transferShares(uint256 seed, uint256 raw) external {
        (address a, address b) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 amt = bound(raw, 1, bal);
        if (_viaOperator(seed) && _operator(seed) != a) {
            address c = _operator(seed);
            vm.prank(a);
            vault.approve(c, amt);
            vm.prank(c);
            require(vault.transferFrom(a, b, amt), "share transferFrom");
            operatorOk++;
        } else {
            vm.prank(a);
            require(vault.transfer(b, amt), "share transfer");
        }
        _move(a, b, amt * ghostNav);
        ghostShares[a] -= amt;
        ghostShares[b] += amt;
        transferOk++;
    }

    /// @dev An actor gives wsgem to the vault: its entitlement drops by the gift, so any
    /// later recovery of it (the inflation-attack payoff) would breach the ledger.
    function donateWsgem(uint256 seed, uint256 raw) external {
        address a = _payer(seed);
        uint256 amt = _pick(seed, raw, WAD, 1, 1e24);
        uint256 mc = wsgem.mintcost();
        uint256 out = _mintWsgemTo(a, _ceilDiv(amt * mc, WAD) + mc);
        require(out >= amt, "donor underfunded");
        vm.prank(a);
        require(wsgem.transfer(address(vault), amt), "donation transfer");
        basis[a] -= SafeCast.toInt256(amt * ghostNav);
        ghostDonated += amt;
        donateOk++;
    }

    /*//////////////////////// market levers /////////////////////*/

    /// @dev NAV accrues: up by 1..200 bps after 1 second..30 days, the yield arriving in
    /// the wsgem's pool as gem. Every actor's entitlement is re-based by its
    /// wsgem-denominated holdings (wallet wsgem plus shares), exactly; share balances, the
    /// supply and the vault's holdings must not move.
    function accrue(uint256 raw) external {
        uint256 nav = ghostNav;
        uint256 next = nav + nav * bound(raw, 1, 200) / 10_000;
        if (next == nav) next = nav + 1;
        uint256 supply = vault.totalSupply();
        uint256 held = wsgem.balanceOf(address(vault));
        uint256[3] memory bal;
        for (uint256 i = 0; i < 3; i++) {
            address a = actors[i];
            bal[i] = vault.balanceOf(a);
            uint256 tokens = wsgem.balanceOf(a) + bal[i];
            basis[a] = basis[a] + SafeCast.toInt256(tokens * next) - SafeCast.toInt256(tokens * nav);
        }
        vm.warp(block.timestamp + bound(raw >> 128, 1, 30 days));
        pip.poke(next);
        gem.mint(address(wsgem), wsgem.totalSupply() * (next - nav) / WAD);
        ghostNav = next;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.balanceOf(actors[i]) != bal[i]) sharesMovedOnAccrue++;
        }
        if (vault.totalSupply() != supply || wsgem.balanceOf(address(vault)) != held) sharesMovedOnAccrue++;
        accrueOk++;
    }

    /// @dev NAV marks down (the oracle is permissioned and non-monotonic), never below half
    /// its initial value: every actor's entitlement is re-based by its wsgem-denominated
    /// holdings, exactly, nothing moves in the pool, and no balance may move.
    function markdown(uint256 raw) external {
        uint256 nav = ghostNav;
        if (nav <= navFloor) return;
        uint256 next = bound(raw, navFloor, nav - 1);
        uint256 supply = vault.totalSupply();
        uint256 held = wsgem.balanceOf(address(vault));
        uint256[3] memory bal;
        for (uint256 i = 0; i < 3; i++) {
            address a = actors[i];
            bal[i] = vault.balanceOf(a);
            uint256 tokens = wsgem.balanceOf(a) + bal[i];
            basis[a] = basis[a] + SafeCast.toInt256(tokens * next) - SafeCast.toInt256(tokens * nav);
        }
        pip.poke(next);
        ghostNav = next;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.balanceOf(actors[i]) != bal[i]) sharesMovedOnAccrue++;
        }
        if (vault.totalSupply() != supply || wsgem.balanceOf(address(vault)) != held) sharesMovedOnAccrue++;
        markdownOk++;
    }

    /// @dev Gem given to the vault by nobody in the ledger: no entitlement moves, so an
    /// actor recovering any of it would breach the ledger.
    function donateGem(uint256 raw) external {
        uint256 amt = bound(raw, 1, _gemMax());
        gem.mint(address(vault), amt);
        ghostGemDonated += amt;
        donateGemOk++;
    }

    /// @dev Entry and exit fees anywhere in [0, 3%], independently, so the costs usually
    /// differ from nav and from each other and sometimes coincide.
    function setFees(uint256 rawIn, uint256 rawOut) external {
        act.setBpsin(bound(rawIn, 0, 300));
        act.setBpsout(bound(rawOut, 0, 300));
        setFeesOk++;
    }

    /*//////////////////////// round trips ///////////////////////*/

    /// @dev In and straight back out through each pairing of an entry and an exit leg, by
    /// one actor in one call: the shape a rounding exploit takes. Liquidity is guaranteed
    /// because the exit claims at most the gem the entry just paid into the pool. The two
    /// other actors are snapshotted around the lap and must come out where they went in.
    function roundTrip(uint256 seed, uint256 which, uint256 raw) external {
        address a = _payer(seed);
        uint256 mc = wsgem.mintcost();
        Bystander[2] memory others = _snapOthers(a);
        bool ok;
        which = which % 4;
        if (which == 0) ok = _rtDepositThenRedeem(a, _pick(seed, raw, mc, mc, _gemMax()), false);
        else if (which == 1) ok = _rtMintThenWithdraw(a, _pick(seed, raw, WAD, WAD, 1e24));
        else if (which == 2) ok = _rtDepositThenRedeem(a, _pick(seed, raw, mc, mc, _gemMax()), true);
        else ok = _rtDepositWsgemThenWithdraw(a, _pick(seed, raw, mc, mc, _gemMax()));
        if (!ok) {
            legReverted++;
            return;
        }
        _checkOthers(others);
        roundTripOk++;
    }

    /// @dev deposit -> redeem (gem back) or -> redeemToWsgem; the exit burns exactly the
    /// shares the entry minted, so the share ghost is untouched net.
    function _rtDepositThenRedeem(address a, uint256 gemIn, bool toWsgem) internal returns (bool ok) {
        uint256 expected = gemIn * WAD / wsgem.mintcost();
        _fund(a, gemIn);
        vm.prank(a);
        gem.approve(address(vault), gemIn);
        uint256 shares;
        (ok, shares) = _call(a, abi.encodeCall(vault.deposit, (gemIn, a)));
        if (!ok) return false;
        if (shares != expected) modelMismatch++;
        modelLoss[a] += gemIn * WAD - expected * ghostNav;
        uint256 got;
        if (toWsgem) {
            (ok, got) = _call(a, abi.encodeCall(vault.redeemToWsgem, (expected, a, a)));
            if (ok && got != expected) modelMismatch++;
        } else {
            uint256 claim = expected * wsgem.burncost() / WAD;
            (ok, got) = _call(a, abi.encodeCall(vault.redeem, (expected, a, a)));
            if (!ok) return false;
            if (got != claim) modelMismatch++;
            modelLoss[a] += expected * ghostNav - claim * WAD;
        }
    }

    /// @dev mint -> withdraw of the shares' full gem claim; the withdraw may burn fewer
    /// shares than were minted (ceil of a floor), the difference stays with the actor.
    function _rtMintThenWithdraw(address a, uint256 shares) internal returns (bool ok) {
        uint256 unit = wsgem.mintcost();
        uint256 expected = _ceilDiv(shares * unit, WAD);
        _fund(a, expected);
        vm.prank(a);
        gem.approve(address(vault), expected);
        uint256 got;
        (ok, got) = _call(a, abi.encodeCall(vault.mint, (shares, a)));
        if (!ok) return false;
        if (got != expected) modelMismatch++;
        _surplus(expected, unit, shares);
        modelLoss[a] += expected * WAD - shares * ghostNav;
        ghostShares[a] += shares;
        return _rtWithdrawClaim(a, shares);
    }

    /// @dev depositWsgem -> withdraw of the shares' full gem claim.
    function _rtDepositWsgemThenWithdraw(address a, uint256 gemIn) internal returns (bool ok) {
        uint256 out = _mintWsgemTo(a, gemIn);
        vm.prank(a);
        wsgem.approve(address(vault), out);
        uint256 shares;
        (ok, shares) = _call(a, abi.encodeCall(vault.depositWsgem, (out, a)));
        if (!ok) return false;
        if (shares != out) modelMismatch++;
        ghostShares[a] += out;
        return _rtWithdrawClaim(a, out);
    }

    /// @dev Withdraws floor(shares * burncost), the gem `redeem(shares)` would pay; the
    /// model burns ceil(claim / burncost) shares.
    function _rtWithdrawClaim(address a, uint256 shares) internal returns (bool ok) {
        uint256 bc = wsgem.burncost();
        uint256 back = shares * bc / WAD;
        uint256 needed = _ceilDiv(back * WAD, bc);
        uint256 got;
        (ok, got) = _call(a, abi.encodeCall(vault.withdraw, (back, a, a)));
        if (!ok) return false;
        if (got != needed) modelMismatch++;
        modelLoss[a] += needed * ghostNav - back * WAD;
        _residue(needed, bc, back);
        ghostShares[a] -= needed;
    }
}

contract WsgemVaultRoundingInvariantTest is InvariantBase {
    RoundingLedgerHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler = new RoundingLedgerHandler(vault, wsgem, gem, pip, act);
        pip.kiss(address(handler)); // accrue
        act.rely(address(handler)); // fee setters
        targetContract(address(handler));
    }

    /// @dev An actor's holdings in ledger units: gem, plus wallet wsgem and shares at nav.
    function _value(address a, uint256 nav) internal view returns (int256) {
        return SafeCast.toInt256(gem.balanceOf(a) * WAD + (wsgem.balanceOf(a) + vault.balanceOf(a)) * nav);
    }

    /// @dev No actor holds more than it is entitled to, and its shortfall is exactly what
    /// the reference model charged it in fees and rounding; share balances moved only
    /// through the legs; every share still claims one wsgem and the quotes match the
    /// wsgem's own path.
    function invariant_RoundingLedger() public view {
        uint256 nav = handler.ghostNav();
        assertEq(wsgem.navprice(), nav, "ghost nav != oracle");
        assertEq(handler.legReverted(), 0, "a leg bounded to succeed reverted");
        assertEq(handler.modelMismatch(), 0, "a leg returned something other than the reference model");
        assertEq(handler.sharesMovedOnAccrue(), 0, "NAV move moved a share balance or holding");
        assertEq(handler.bystanderMoved(), 0, "a lap moved a bystander's position or quotes");
        assertEq(vault.convertToAssets(WAD), nav, "share price != nav");
        assertEq(vault.previewMint(WAD), wsgem.mintcost(), "gem entry quote != wsgem mintcost");
        assertEq(vault.previewRedeem(WAD), wsgem.burncost(), "gem exit quote != wsgem burncost");
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            uint256 bal = vault.balanceOf(a);
            sum += bal;
            assertEq(bal, handler.ghostShares(a), "share balance moved outside the legs");
            int256 value = _value(a, nav);
            int256 entitled = handler.basis(a);
            assertLe(value, entitled, "actor holds more than it paid for: rounding paid out");
            assertEq(
                SafeCast.toUint256(entitled - value), handler.modelLoss(a), "actor's cost != fees + rounding per model"
            );
            assertEq(vault.previewRedeemToWsgem(bal), bal, "share claim not 1:1");
            assertEq(vault.maxRedeemToWsgem(a), bal, "maxRedeemToWsgem != balance");
            assertEq(vault.convertToAssets(bal), bal * nav / WAD, "convertToAssets != balance at nav");
        }
        assertEq(sum, vault.totalSupply(), "shares held outside the actors");
    }

    /// @dev What the vault holds is exactly what the ledger says it should: one wsgem per
    /// share plus mint excess and donations, and only withdraw residue in gem.
    function invariant_VaultHoldingsAccounted() public view {
        assertEq(
            wsgem.balanceOf(address(vault)),
            vault.totalSupply() + handler.ghostMintExcess() + handler.ghostDonated(),
            "held wsgem != shares + mint excess + donations"
        );
        assertEq(
            gem.balanceOf(address(vault)),
            handler.ghostGemDust() + handler.ghostGemDonated(),
            "vault gem != withdraw residue + gem gifts"
        );
        assertEq(handler.residueExceeded(), 0, "withdraw residue above bound");
        assertEq(handler.surplusExceeded(), 0, "mint surplus above bound");
    }

    function invariant_Spec() public view {
        _checkSpec([handler.actor(0), handler.actor(1), handler.actor(2)], true);
    }

    function test_HandlerMint_MissingBackingStaysVisible() public {
        _checkMissingMintBacking(false);
    }

    function test_HandlerRoundTrip_MissingBackingStaysVisible() public {
        _checkMissingMintBacking(true);
    }

    /// @dev Simulate a mint reporting success without delivering wsgem. The handler must
    /// finish so fail_on_revert=false cannot discard the bad state before the invariant.
    function _checkMissingMintBacking(bool roundTrip) internal {
        uint256 shares = WAD + 1;
        uint256 unit = wsgem.mintcost();
        uint256 assets = (shares * unit + WAD - 1) / WAD;
        uint256 expectedWsgem = assets * WAD / unit;
        vm.mockCall(address(wsgem), abi.encodeCall(wsgem.mint, (assets)), abi.encode(expectedWsgem));

        uint256 seed = roles(0, 0, 0, false, 5);
        if (roundTrip) handler.roundTrip(seed, 1, shares);
        else handler.mint(seed, shares);

        assertEq(vault.totalSupply(), shares, "bad mint was rolled back");
        assertEq(wsgem.balanceOf(address(vault)), 0, "mock unexpectedly delivered backing");
        assertEq(handler.ghostShares(handler.actor(0)), shares, "share ledger was rolled back");
        assertEq(handler.ghostMintExcess(), expectedWsgem - shares, "surplus must follow the model");
        assertEq(handler.legReverted(), roundTrip ? 1 : 0, "round-trip exit must report the deficit");
        assertEq(handler.mintOk(), roundTrip ? 0 : 1, "standalone mint must finish");

        bytes memory reason =
            bytes(string.concat("held wsgem != shares + mint excess + donations: 0 != ", vm.toString(expectedWsgem)));
        vm.expectRevert(reason);
        this.invariant_VaultHoldingsAccounted();
    }

    function test_HandlerWithdraw_BadReturnStaysVisible() public {
        _checkBadWithdrawReturn(false);
    }

    function test_HandlerRoundTrip_BadWithdrawReturnStaysVisible() public {
        _checkBadWithdrawReturn(true);
    }

    /// @dev A returned share count above the owner's balance must leave a mismatch,
    /// without overflowing the basis or underflowing the share ledger and erasing it.
    function _checkBadWithdrawReturn(bool roundTrip) internal {
        uint256 seed = roles(0, 0, 0, false, 5);
        uint256 shares = WAD + 1;
        uint256 unit = wsgem.burncost();
        uint256 assets = roundTrip ? shares * unit / WAD : unit;
        uint256 needed = (assets * WAD + unit - 1) / unit;
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.withdraw.selector), abi.encode(type(uint256).max));

        if (roundTrip) {
            handler.roundTrip(seed, 1, shares);
        } else {
            handler.mint(seed, shares);
            handler.withdraw(seed, assets);
        }

        assertEq(handler.modelMismatch(), 1, "return mismatch was erased");
        assertEq(handler.legReverted(), 0, "the mock returned successfully");
        assertEq(handler.ghostShares(handler.actor(0)), shares - needed, "share ledger must follow the model");
        assertEq(handler.withdrawOk(), roundTrip ? 0 : 1, "standalone withdraw must finish");
        assertEq(handler.roundTripOk(), roundTrip ? 1 : 0, "round trip must finish");
        vm.expectRevert(bytes("a leg returned something other than the reference model: 1 != 0"));
        this.invariant_RoundingLedger();
    }

    /// @dev Anti-vacuity: every op, both operator paths, receiver != owner, accrual with
    /// balances pinned, equal and unequal costs, the inflation attack shape, and every
    /// amount-shaping mode, then the invariants.
    function test_HandlerWiring_Rounding() public {
        uint256 one = 10 ** gem.decimals();
        address r1 = handler.actor(1);
        handler.deposit(roles(0, 0, 0, false, 5), 5 * one);
        handler.mint(roles(1, 1, 0, false, 5), 3e18);
        handler.depositWsgem(roles(2, 2, 0, false, 5), 4 * one);
        handler.deposit(roles(1, 0, 0, false, 5), 2 * one); // r1 pays, r0 receives
        handler.transferShares(roles(0, 1, 1, true, 0), 1e18); // r0 -> r1, moved by r1

        // NAV accrues: balances pinned, value up, quotes tracking.
        uint256 nav0 = handler.ghostNav();
        uint256 bal1 = vault.balanceOf(r1);
        uint256 worth1 = vault.convertToAssets(bal1);
        handler.accrue(200);
        assertGt(handler.ghostNav(), nav0, "nav did not accrue");
        assertEq(vault.balanceOf(r1), bal1, "accrual moved a share balance");
        assertGt(vault.convertToAssets(bal1), worth1, "accrual did not lift the value");

        handler.redeem(roles(1, 1, 2, true, 5), 1e18); // owner r1, redeemed by r2
        handler.withdraw(roles(0, 1, 0, false, 5), 2 * one); // owner r0, receiver r1
        handler.redeemToWsgem(roles(2, 2, 0, false, 5), 1e18);

        // Equal costs, then unequal costs, each with an entry and an exit.
        handler.setFees(0, 0);
        assertEq(wsgem.burncost(), wsgem.navprice(), "costs not equal");
        handler.deposit(roles(0, 0, 0, false, 5), 3 * one);
        handler.redeem(roles(0, 0, 0, false, 5), 1e18);
        handler.setFees(50, 100);
        assertLt(wsgem.burncost(), wsgem.navprice(), "burncost not below nav");
        assertGt(wsgem.mintcost(), wsgem.navprice(), "mintcost not above nav");
        handler.mint(roles(1, 1, 0, false, 5), 2e18);
        handler.withdraw(roles(1, 1, 0, false, 5), 2 * one);
        handler.accrue(50);

        // NAV marks down: balances pinned, value down, the ledger still exact; then a gem
        // gift to the vault that no actor may recover.
        nav0 = handler.ghostNav();
        bal1 = vault.balanceOf(r1);
        worth1 = vault.convertToAssets(bal1);
        handler.markdown(0);
        assertLt(handler.ghostNav(), nav0, "nav did not mark down");
        assertEq(vault.balanceOf(r1), bal1, "markdown moved a share balance");
        assertLt(vault.convertToAssets(bal1), worth1, "markdown did not cut the value");
        invariant_RoundingLedger();
        handler.donateGem(3 * one);
        assertEq(handler.ghostGemDonated(), 3 * one, "gem gift");
        invariant_VaultHoldingsAccounted();

        // Inflation-attack shape: r0 donates, r1 deposits, r0 exits in full and holds no
        // more than it paid for (the ledger runs mid-test to pin the payoff moment).
        handler.donateWsgem(roles(0, 0, 0, false, 5), 1e18);
        handler.deposit(roles(1, 1, 0, false, 5), 5 * one);
        handler.redeemToWsgem(roles(0, 0, 0, false, 5), type(uint256).max);
        assertEq(vault.balanceOf(handler.actor(0)), 0, "donor did not exit in full");
        assertEq(handler.ghostDonated(), 1e18, "donation");
        invariant_RoundingLedger();

        for (uint256 i = 0; i < 4; i++) {
            handler.roundTrip(roles(i % 3, 0, 0, false, 5), i, 7 * one);
        }
        for (uint256 m = 0; m < 5; m++) {
            handler.deposit(roles(0, 0, 0, false, m), 3);
            handler.redeem(roles(0, 0, 0, false, m), 3);
        }
        handler.setFees(0, 25);

        assertGt(handler.depositOk(), 0, "deposit");
        assertGt(handler.mintOk(), 0, "mint");
        assertGt(handler.depositWsgemOk(), 0, "depositWsgem");
        assertGt(handler.redeemOk(), 0, "redeem");
        assertGt(handler.withdrawOk(), 0, "withdraw");
        assertGt(handler.redeemWsgemOk(), 0, "redeemToWsgem");
        assertGt(handler.transferOk(), 0, "transferShares");
        assertGt(handler.donateOk(), 0, "donateWsgem");
        assertEq(handler.accrueOk(), 2, "accrue");
        assertEq(handler.markdownOk(), 1, "markdown");
        assertEq(handler.donateGemOk(), 1, "donateGem");
        assertEq(handler.setFeesOk(), 3, "setFees");
        assertEq(handler.roundTripOk(), 4, "roundTrip");
        assertGt(handler.operatorOk(), 1, "operator flows");
        assertEq(handler.bystanderMoved(), 0, "bystanders");
        assertEq(handler.surplusExceeded(), 0, "surplus");

        invariant_RoundingLedger();
        invariant_VaultHoldingsAccounted();
        invariant_Spec();
    }
}

contract WsgemVaultRoundingDec6InvariantTest is WsgemVaultRoundingInvariantTest {
    function setUp() public override {
        gemDecimals = 6;
        initNavprice = 1.006e6;
        super.setUp();
    }
}

/*//////////////////////////////////////////////////////////////
                         BACKING DRAIN
//////////////////////////////////////////////////////////////*/

/// @notice Every governable and privileged lever, gem-side pauses and bans, and multi-actor
/// share flows, scoring every op but the issuer's smelt for BACKING FAIRNESS: it may not
/// lower the effective backing ratio `min(held, supply) / supply`, mint a share without
/// receiving a wsgem, release more wsgem than the burned shares' pro-rata claim, or deliver
/// an amount other than the one it returned. Violations are counted, never asserted, so a
/// sequence keeps running after a breach and the invariant sees it.
contract BackingDrainHandler is ActorHandler {
    MaseerPrice internal pip;
    MaseerGate internal act;
    address internal issuer;
    address internal donor = makeAddr("ddonor");

    // Ghosts.
    uint256 public ghostNav; // last non-zero poke
    uint256 public ghostSmelted; // wsgem burned out of the vault by the issuer
    uint256 public floorEff = 1; // backing ratio right after the last smelt, as eff / supply
    uint256 public floorSupply = 1;
    uint256 public lastRelease; // wsgem released by the last served redemption
    uint256 internal navFloor; // markdowns never take the NAV below half its initial value

    // Violation counters (must all stay 0).
    uint256 public backingRatioDropped;
    uint256 public fullBackingLost;
    uint256 public sharesMintedUnbacked;
    uint256 public proRataExceeded;
    uint256 public deliveryMismatch;
    uint256 public residueExceeded;
    uint256 public depositAcceptedInDeficit;
    uint256 public maxReverted;
    uint256 public maxNotTight;
    uint256 public sharesMovedOnAccrue;

    // Op liveness counters (op ran to its end, whatever the outcome).
    uint256 public depositOps;
    uint256 public mintOps;
    uint256 public depositWsgemOps;
    uint256 public redeemOps;
    uint256 public withdrawOps;
    uint256 public redeemWsgemOps;
    uint256 public transferOps;
    uint256 public smeltOps;
    uint256 public healOps;
    uint256 public donateOps;
    uint256 public settleOps;
    uint256 public refillOps;
    uint256 public trickleOps;
    uint256 public setCooldownOps;
    uint256 public clearCooldownOps;
    uint256 public pauseMarketOps;
    uint256 public reopenMarketOps;
    uint256 public setMintWindowOps;
    uint256 public setBurnWindowOps;
    uint256 public pauseOracleOps;
    uint256 public unpauseOracleOps;
    uint256 public accrueOps;
    uint256 public markdownOps;
    uint256 public setBpsinOps;
    uint256 public setBpsoutOps;
    uint256 public setCapacityOps;
    uint256 public clearCapacityOps;
    uint256 public gemPauseOps;
    uint256 public gemUnpauseOps;
    uint256 public gemBanVaultOps;
    uint256 public gemUnbanVaultOps;
    uint256 public gemBanWsgemOps;
    uint256 public gemUnbanWsgemOps;
    uint256 public gemBanActorOps;
    uint256 public gemUnbanActorOps;
    uint256 public probeOps;

    // Outcome counters (how often each state actually bit; for the wiring test).
    uint256 public depositsServed;
    uint256 public depositsBlocked;
    uint256 public redeemsServed;
    uint256 public redeemsBlocked;
    uint256 public probesRun;
    uint256 public probesSkipped;

    constructor(WsgemVault _vault, Wsgem _wsgem, MockGem _gem, MaseerPrice _pip, MaseerGate _act, address _issuer)
        ActorHandler(_vault, _wsgem, _gem, "d")
    {
        pip = _pip;
        act = _act;
        issuer = _issuer;
        ghostNav = wsgem.navprice();
        navFloor = ghostNav / 2;
    }

    /*//////////////////////// scoring ///////////////////////////*/

    /// @dev Snapshots held wsgem and share supply around an op and scores the change: the
    /// effective backing ratio may not fall, full backing may not be lost, minted shares
    /// must be matched by received wsgem, and burned shares may release at most their
    /// pro-rata claim.
    modifier guarded() {
        uint256 h0 = wsgem.balanceOf(address(vault));
        uint256 s0 = vault.totalSupply();
        _;
        _score(h0, s0, wsgem.balanceOf(address(vault)), vault.totalSupply());
    }

    function _score(uint256 h0, uint256 s0, uint256 h1, uint256 s1) internal {
        uint256 e0 = h0 < s0 ? h0 : s0;
        uint256 e1 = h1 < s1 ? h1 : s1;
        if (s0 != 0 && s1 != 0 && e1 * s0 < e0 * s1) backingRatioDropped++;
        if (h0 >= s0 && h1 < s1) fullBackingLost++;
        if (s1 > s0 && (h1 < h0 || h1 - h0 < s1 - s0)) sharesMintedUnbacked++;
        if (s1 < s0) {
            uint256 released = h1 < h0 ? h0 - h1 : 0;
            if (released > (s0 - s1) * e0 / s0) proRataExceeded++;
        }
    }

    function _scoreDeposit(bool ok, bool wasInDeficit) internal {
        if (ok) {
            depositsServed++;
            if (wasInDeficit) depositAcceptedInDeficit++;
        } else {
            depositsBlocked++;
        }
    }

    function _scoreRedeem(bool ok) internal {
        if (ok) redeemsServed++;
        else redeemsBlocked++;
    }

    /*//////////////////////// guards ////////////////////////////*/

    // The gem screens every party to an approval or transfer; the wsgem screens every
    // party to a wsgem approval or transfer. Skip what would revert inside the handler and
    // let the vault call itself report the outcome.

    function _approveGem(address a) internal {
        if (gem.isBanned(a) || gem.isBanned(address(vault))) return;
        vm.prank(a);
        gem.approve(address(vault), type(uint256).max);
    }

    function _approveWsgem(address a) internal {
        if (gem.isBanned(a) || gem.isBanned(address(vault))) return;
        vm.prank(a);
        wsgem.approve(address(vault), type(uint256).max);
    }

    /// @dev Mints wsgem to `u` directly; returns 0 (and does nothing) when the wsgem's own
    /// mint would fail, so the op degrades to a no-op rather than reverting.
    function _tryMintWsgemTo(address u, uint256 gemIn) internal returns (uint256 out) {
        if (gem.isBanned(u) || gem.isBanned(address(wsgem))) return 0;
        gem.mint(u, gemIn);
        vm.startPrank(u);
        gem.approve(address(wsgem), gemIn);
        try wsgem.mint(gemIn) returns (uint256 o) {
            out = o;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Donor gives `amt` wsgem to the vault; false when nothing could be minted for it
    /// or the vault cannot receive.
    function _donate(uint256 amt) internal returns (bool) {
        if (gem.isBanned(address(vault))) return false;
        uint256 unit = wsgem.mintcost();
        if (unit == 0) return false;
        uint256 out = _tryMintWsgemTo(donor, _ceilDiv(amt * unit, WAD) + unit);
        if (out < amt) return false;
        vm.prank(donor);
        require(wsgem.transfer(address(vault), amt), "donation transfer");
        return true;
    }

    /*//////////////////////// vault legs ////////////////////////*/

    function deposit(uint256 seed, uint256 raw) external guarded {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 assets = bound(raw, 1, _gemMax());
        gem.mint(a, assets);
        _approveGem(a);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) = _call(a, abi.encodeCall(vault.deposit, (assets, r)));
        _scoreDeposit(ok, inDeficit);
        depositOps++;
    }

    function mint(uint256 seed, uint256 raw) external guarded {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 shares = bound(raw, 1, 1e24);
        gem.mint(a, vault.previewMint(shares));
        _approveGem(a);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) = _call(a, abi.encodeCall(vault.mint, (shares, r)));
        _scoreDeposit(ok, inDeficit);
        mintOps++;
    }

    function depositWsgem(uint256 seed, uint256 raw) external guarded {
        (address a, address r) = (_payer(seed), _receiver(seed));
        uint256 out = _tryMintWsgemTo(a, bound(raw, 1, _gemMax()));
        if (out == 0) {
            depositWsgemOps++;
            return;
        }
        _approveWsgem(a);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) = _call(a, abi.encodeCall(vault.depositWsgem, (out, r)));
        _scoreDeposit(ok, inDeficit);
        depositWsgemOps++;
    }

    function redeem(uint256 seed, uint256 raw) external guarded {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(o);
        if (bal == 0) {
            redeemOps++;
            return;
        }
        uint256 shares = bound(raw, 1, bal);
        uint256 g0 = gem.balanceOf(r);
        uint256 h0 = wsgem.balanceOf(address(vault));
        (bool ok, uint256 assets) = _exec(seed, o, shares, abi.encodeCall(vault.redeem, (shares, r, o)));
        if (ok) {
            if (gem.balanceOf(r) - g0 != assets) deliveryMismatch++;
            lastRelease = h0 - wsgem.balanceOf(address(vault));
        }
        _scoreRedeem(ok);
        redeemOps++;
    }

    struct WithdrawSnap {
        uint256 assets;
        uint256 unit;
        uint256 receiverGem;
        uint256 vaultGem;
        uint256 vaultWsgem;
    }

    function withdraw(uint256 seed, uint256 raw) external guarded {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(o);
        if (bal == 0) {
            withdrawOps++;
            return;
        }
        // Bound to what the balance quotes for so a failure is a vault gate, not "burn
        // amount exceeds balance".
        uint256 cap = vault.previewRedeem(bal);
        WithdrawSnap memory snap = WithdrawSnap({
            assets: bound(raw, 1, cap == 0 ? 1 : cap),
            unit: wsgem.burncost(),
            receiverGem: gem.balanceOf(r),
            vaultGem: gem.balanceOf(address(vault)),
            vaultWsgem: wsgem.balanceOf(address(vault))
        });
        (bool ok,) =
            _exec(seed, o, vault.previewWithdraw(snap.assets), abi.encodeCall(vault.withdraw, (snap.assets, r, o)));
        if (ok) _checkWithdraw(r, snap);
        _scoreRedeem(ok);
        withdrawOps++;
    }

    /// @dev Exactly `assets` reached the receiver, the vault kept at most the README's
    /// residue bound, and the wsgem released is recorded.
    function _checkWithdraw(address r, WithdrawSnap memory snap) internal {
        if (gem.balanceOf(r) - snap.receiverGem != snap.assets) deliveryMismatch++;
        uint256 vaultGem = gem.balanceOf(address(vault));
        if (vaultGem < snap.vaultGem) residueExceeded++; // paid out more than the claim it received
        else if (snap.unit != 0 && vaultGem - snap.vaultGem > _ceilDiv(snap.unit, WAD) - 1) residueExceeded++;
        lastRelease = snap.vaultWsgem - wsgem.balanceOf(address(vault));
    }

    function redeemToWsgem(uint256 seed, uint256 raw) external guarded {
        (address o, address r) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(o);
        if (bal == 0) {
            redeemWsgemOps++;
            return;
        }
        uint256 shares = bound(raw, 1, bal);
        uint256 w0 = wsgem.balanceOf(r);
        (bool ok, uint256 out) = _exec(seed, o, shares, abi.encodeCall(vault.redeemToWsgem, (shares, r, o)));
        if (ok) {
            if (wsgem.balanceOf(r) - w0 != out) deliveryMismatch++;
            lastRelease = out;
        }
        _scoreRedeem(ok);
        redeemWsgemOps++;
    }

    function transferShares(uint256 seed, uint256 raw) external guarded {
        (address a, address b) = (_payer(seed), _receiver(seed));
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) {
            transferOps++;
            return;
        }
        uint256 amt = bound(raw, 1, bal);
        if (_viaOperator(seed) && _operator(seed) != a) {
            address c = _operator(seed);
            vm.prank(a);
            vault.approve(c, amt);
            vm.prank(c);
            require(vault.transferFrom(a, b, amt), "share transferFrom");
            operatorOk++;
        } else {
            vm.prank(a);
            require(vault.transfer(b, amt), "share transfer");
        }
        transferOps++;
    }

    /*//////////////////////// max* boundary /////////////////////*/

    /// @dev `x(max*() + 1)` must revert wherever the max is finite and below what the
    /// actor could otherwise ask, and `x(max*())` must then succeed (a harmless no-op at
    /// 0). Probed in that order so the tightness check sees the state the max was quoted
    /// on. For the gem exits, `thin` usually drains the wsgem's pool to a few gem first so
    /// the liquidity-capped branch of the max* arithmetic is the one probed; for the wsgem
    /// deposit (0 or unlimited, no `+1`) it sizes the deposit. Skipped for a banned actor:
    /// `max*` model the vault's compliance, not the caller's.
    function probeMaxBoundary(uint256 seed, uint256 which, uint256 thin) external guarded {
        address a = _payer(seed);
        which = which % 6;
        bool ok;
        if (gem.isBanned(a)) {
            probesSkipped++;
            probeOps++;
            return;
        }
        if ((which == 2 || which == 3) && thin % 4 != 0) {
            try wsgem.settle() {} catch {}
            gem.mint(address(wsgem), bound(thin, 1, 10 * scale));
        }
        if (which == 0) {
            uint256 m = vault.maxDeposit(a);
            if (m == type(uint256).max) {
                probesSkipped++;
                probeOps++;
                return;
            }
            uint256 x = _min(m, _gemMax());
            gem.mint(a, x + 1);
            _approveGem(a);
            if (m < _gemMax()) {
                (ok,) = _call(a, abi.encodeCall(vault.deposit, (m + 1, a)));
                if (ok) maxNotTight++;
            }
            (ok,) = _call(a, abi.encodeCall(vault.deposit, (x, a)));
            if (!ok) maxReverted++;
        } else if (which == 1) {
            uint256 m = vault.maxMint(a);
            if (m == type(uint256).max) {
                probesSkipped++;
                probeOps++;
                return;
            }
            uint256 x = _min(m, 1e24);
            gem.mint(a, vault.previewMint(x + 1));
            _approveGem(a);
            if (m < 1e24) {
                (ok,) = _call(a, abi.encodeCall(vault.mint, (m + 1, a)));
                if (ok) maxNotTight++;
            }
            (ok,) = _call(a, abi.encodeCall(vault.mint, (x, a)));
            if (!ok) maxReverted++;
        } else if (which == 2) {
            uint256 m = vault.maxWithdraw(a);
            (ok,) = _call(a, abi.encodeCall(vault.withdraw, (m + 1, a, a)));
            if (ok) maxNotTight++;
            (ok,) = _call(a, abi.encodeCall(vault.withdraw, (m, a, a)));
            if (!ok) maxReverted++;
        } else if (which == 3) {
            uint256 m = vault.maxRedeem(a);
            if (m < vault.balanceOf(a)) {
                (ok,) = _call(a, abi.encodeCall(vault.redeem, (m + 1, a, a)));
                if (ok) maxNotTight++;
            }
            (ok,) = _call(a, abi.encodeCall(vault.redeem, (m, a, a)));
            if (!ok) maxReverted++;
        } else if (which == 4) {
            uint256 m = vault.maxRedeemToWsgem(a);
            if (m < vault.balanceOf(a)) {
                (ok,) = _call(a, abi.encodeCall(vault.redeemToWsgem, (m + 1, a, a)));
                if (ok) maxNotTight++;
            }
            (ok,) = _call(a, abi.encodeCall(vault.redeemToWsgem, (m, a, a)));
            if (!ok) maxReverted++;
        } else {
            // 0 or unlimited: a zero deposit must be a harmless no-op, and a bounded
            // deposit must go through when the wsgem's own mint can fund it.
            uint256 m = vault.maxDepositWsgem(a);
            uint256 amt;
            if (m == type(uint256).max) {
                uint256 unit = wsgem.mintcost();
                if (unit != 0) amt = _tryMintWsgemTo(a, bound(thin, unit, _gemMax()));
                if (amt != 0) _approveWsgem(a);
            }
            (ok,) = _call(a, abi.encodeCall(vault.depositWsgem, (amt, a)));
            if (!ok) maxReverted++;
        }
        probesRun++;
        probeOps++;
    }

    /*//////////////////////// privileged & governable levers ////*/

    /// @dev The one op that may lower the backing ratio; it resets the ratio floor.
    function smelt(uint256 raw) external {
        uint256 held = wsgem.balanceOf(address(vault));
        if (held == 0) {
            smeltOps++;
            return;
        }
        uint256 amt = bound(raw, 1, held);
        vm.prank(issuer);
        wsgem.smelt(address(vault), amt);
        ghostSmelted += amt;
        uint256 supply = vault.totalSupply();
        uint256 h = held - amt;
        (floorEff, floorSupply) = supply == 0 ? (uint256(1), uint256(1)) : (h < supply ? h : supply, supply);
        smeltOps++;
    }

    /// @dev Donating wsgem back is the deficit-remediation path.
    function heal(uint256 raw) external guarded {
        uint256 d = vault.deficit();
        if (d != 0) _donate(bound(raw, 1, d));
        healOps++;
    }

    function donate(uint256 raw) external guarded {
        _donate(bound(raw, 1, 1e24));
        donateOps++;
    }

    /// @dev Drains every gem not reserved for queued claims out of the wsgem (to `flo`);
    /// fails harmlessly while the gem is paused or the wsgem is banned.
    function settle() external guarded {
        try wsgem.settle() {} catch {}
        settleOps++;
    }

    function refillLiquidity(uint256 raw) external guarded {
        gem.mint(address(wsgem), bound(raw, 1, _gemMax()));
        refillOps++;
    }

    /// @dev A thin refill (up to ten gem) so the liquidity-capped `max*` boundary is common.
    function trickleLiquidity(uint256 raw) external guarded {
        gem.mint(address(wsgem), bound(raw, 1, 10 * scale));
        trickleOps++;
    }

    function setCooldown(uint256 raw) external guarded {
        act.setCooldown(bound(raw, 1, 365 days));
        setCooldownOps++;
    }

    function clearCooldown() external guarded {
        act.setCooldown(0);
        clearCooldownOps++;
    }

    function pauseMarket() external guarded {
        act.pauseMarket();
        pauseMarketOps++;
    }

    function reopenMarket() external guarded {
        act.setOpenMint(block.timestamp);
        act.setOpenBurn(block.timestamp);
        act.file("haltmint", type(uint256).max);
        act.file("haltburn", type(uint256).max);
        reopenMarketOps++;
    }

    /// @dev The mint and burn windows are independent gates (the open timestamps are
    /// never in the future, so the halt alone decides).
    function setMintWindow(bool open) external guarded {
        act.file("haltmint", open ? type(uint256).max : 0);
        setMintWindowOps++;
    }

    function setBurnWindow(bool open) external guarded {
        act.file("haltburn", open ? type(uint256).max : 0);
        setBurnWindowOps++;
    }

    function pauseOracle() external guarded {
        pip.pause();
        pauseOracleOps++;
    }

    function unpauseOracle() external guarded {
        pip.poke(ghostNav);
        unpauseOracleOps++;
    }

    /// @dev NAV accrues: up by 1..200 bps after 1 second..30 days, the yield arriving in
    /// the wsgem's pool as gem; share balances and the supply must not move. Also brings
    /// a paused oracle back live.
    function accrue(uint256 raw) external guarded {
        uint256 nav = ghostNav;
        uint256 next = nav + nav * bound(raw, 1, 200) / 10_000;
        if (next == nav) next = nav + 1;
        uint256 supply = vault.totalSupply();
        uint256[3] memory bal = [vault.balanceOf(actors[0]), vault.balanceOf(actors[1]), vault.balanceOf(actors[2])];
        vm.warp(block.timestamp + bound(raw >> 128, 1, 30 days));
        pip.poke(next);
        gem.mint(address(wsgem), wsgem.totalSupply() * (next - nav) / WAD);
        ghostNav = next;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.balanceOf(actors[i]) != bal[i]) sharesMovedOnAccrue++;
        }
        if (vault.totalSupply() != supply) sharesMovedOnAccrue++;
        accrueOps++;
    }

    /// @dev NAV marks down (never below half its initial value) with nothing moving in the
    /// pool; share balances and the supply must not move. Also brings a paused oracle back
    /// live.
    function markdown(uint256 raw) external guarded {
        uint256 nav = ghostNav;
        if (nav <= navFloor) {
            markdownOps++;
            return;
        }
        uint256 next = bound(raw, navFloor, nav - 1);
        uint256 supply = vault.totalSupply();
        uint256[3] memory bal = [vault.balanceOf(actors[0]), vault.balanceOf(actors[1]), vault.balanceOf(actors[2])];
        pip.poke(next);
        ghostNav = next;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.balanceOf(actors[i]) != bal[i]) sharesMovedOnAccrue++;
        }
        if (vault.totalSupply() != supply) sharesMovedOnAccrue++;
        markdownOps++;
    }

    function setBpsin(uint256 raw) external guarded {
        act.setBpsin(bound(raw, 0, 500));
        setBpsinOps++;
    }

    function setBpsout(uint256 raw) external guarded {
        act.setBpsout(bound(raw, 0, 500));
        setBpsoutOps++;
    }

    function setCapacity(uint256 raw) external guarded {
        act.setCapacity(bound(raw, 0, 1e30));
        setCapacityOps++;
    }

    function clearCapacity() external guarded {
        act.setCapacity(type(uint256).max);
        clearCapacityOps++;
    }

    /*//////////////////////// gem-side levers ///////////////////*/

    function gemPause() external guarded {
        gem.pause();
        gemPauseOps++;
    }

    function gemUnpause() external guarded {
        gem.unpause();
        gemUnpauseOps++;
    }

    function gemBanVault() external guarded {
        gem.ban(address(vault));
        gemBanVaultOps++;
    }

    function gemUnbanVault() external guarded {
        gem.unban(address(vault));
        gemUnbanVaultOps++;
    }

    function gemBanWsgem() external guarded {
        gem.ban(address(wsgem));
        gemBanWsgemOps++;
    }

    function gemUnbanWsgem() external guarded {
        gem.unban(address(wsgem));
        gemUnbanWsgemOps++;
    }

    function gemBanActor(uint256 seed) external guarded {
        gem.ban(_payer(seed));
        gemBanActorOps++;
    }

    function gemUnbanActor(uint256 seed) external guarded {
        gem.unban(_payer(seed));
        gemUnbanActorOps++;
    }
}

contract WsgemVaultDrainInvariantTest is InvariantBase {
    BackingDrainHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler = new BackingDrainHandler(vault, wsgem, gem, pip, act, issuer);
        pip.kiss(address(handler)); // accrue, unpause
        pip.rely(address(handler)); // pause
        act.rely(address(handler)); // gate setters
        targetContract(address(handler));
    }

    /// @dev Since the last privileged burn no user action has lowered anyone's backing
    /// ratio, backing has only ever been destroyed by the issuer, every share is held by an
    /// actor, all outstanding wsgem claims are covered by what is held, and the max*
    /// quotes go dark exactly with the legs they gate.
    function invariant_BackingFairness() public view {
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 supply = vault.totalSupply();
        uint256 eff = held < supply ? held : supply;
        if (supply != 0) {
            assertGe(eff * handler.floorSupply(), handler.floorEff() * supply, "backing ratio below the last smelt");
        }
        assertGe(held + handler.ghostSmelted(), supply, "backing destroyed by a user op");

        bool pass = wsgem.canPass(address(vault));
        bool gemOk = vault.gemTransfersAvailable();
        uint256 sum;
        uint256 claims;
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actor(i);
            uint256 bal = vault.balanceOf(a);
            uint256 claim = vault.previewRedeemToWsgem(bal);
            sum += bal;
            claims += claim;
            if (!gemOk) {
                assertEq(vault.maxDeposit(a), 0, "maxDeposit while gem transfers unavailable");
                assertEq(vault.maxMint(a), 0, "maxMint while gem transfers unavailable");
                assertEq(vault.maxWithdraw(a), 0, "maxWithdraw while gem transfers unavailable");
                assertEq(vault.maxRedeem(a), 0, "maxRedeem while gem transfers unavailable");
            }
            assertEq(vault.maxRedeemToWsgem(a), pass && claim != 0 ? bal : 0, "maxRedeemToWsgem gating");
            assertEq(
                vault.maxDepositWsgem(a), vault.deficit() == 0 && pass ? type(uint256).max : 0, "maxDepositWsgem gating"
            );
        }
        assertEq(sum, supply, "shares held outside the actors");
        assertLe(claims, held, "outstanding wsgem claims exceed holdings");
    }

    function invariant_NoViolations() public view {
        assertEq(handler.backingRatioDropped(), 0, "a user op lowered the backing ratio");
        assertEq(handler.fullBackingLost(), 0, "a user op broke full backing");
        assertEq(handler.sharesMintedUnbacked(), 0, "shares minted without wsgem received");
        assertEq(handler.proRataExceeded(), 0, "redemption released above pro-rata");
        assertEq(handler.deliveryMismatch(), 0, "delivered amount != returned amount");
        assertEq(handler.residueExceeded(), 0, "withdraw residue above bound");
        assertEq(handler.depositAcceptedInDeficit(), 0, "deposit accepted in deficit");
        assertEq(handler.maxReverted(), 0, "x(max*()) reverted");
        assertEq(handler.maxNotTight(), 0, "x(max*() + 1) succeeded");
        assertEq(handler.sharesMovedOnAccrue(), 0, "NAV move moved a share balance");
    }

    function invariant_NoDanglingClaims() public view {
        assertEq(wsgem.totalPending(), 0, "queued wsgem redemption claim");
    }

    function invariant_Spec() public view {
        _checkSpec([handler.actor(0), handler.actor(1), handler.actor(2)], true);
    }

    /// @dev Anti-vacuity: a deterministic walk through every adversarial state, checking
    /// that each lever actually bit (blocked/served counters move), that the pro-rata
    /// payout and the ratio floor show up after a smelt, that the boundary probes run
    /// where the max* are capped, and that no violation counter ever moves.
    function test_HandlerWiring_Drain() public {
        uint256 one = 10 ** gem.decimals();
        address a0 = handler.actor(0);
        address a1 = handler.actor(1);

        // Positions through every deposit leg, a plain transfer, an operator transfer and
        // an operator redemption.
        handler.deposit(roles(0, 0, 0, false, 0), 10 * one);
        handler.mint(roles(1, 1, 0, false, 0), 5e18);
        handler.depositWsgem(roles(2, 2, 0, false, 0), 8 * one);
        assertEq(handler.depositsServed(), 3, "seed deposits");
        handler.transferShares(roles(0, 1, 0, false, 0), 1e18);
        handler.transferShares(roles(0, 1, 1, true, 0), 1e18);
        handler.redeem(roles(1, 1, 2, true, 0), 1e18);
        assertEq(handler.redeemsServed(), 1, "operator redeem");
        assertEq(handler.operatorOk(), 2, "operator flows");
        uint256 nav = wsgem.navprice();
        assertEq(vault.convertToAssets(1e18), nav, "fully backed prices at nav");

        // Smelt: ratio floor snapshotted, price marked down, every deposit leg blocked, the
        // wsgem leg pays pro-rata; heal restores par.
        handler.smelt(3e18);
        assertGt(vault.deficit(), 0, "deficit after smelt");
        assertEq(handler.floorSupply(), vault.totalSupply(), "floor supply");
        assertEq(handler.floorEff(), wsgem.balanceOf(address(vault)), "floor backing");
        assertLt(vault.convertToAssets(1e18), nav, "price not marked down");
        uint256 blocked = handler.depositsBlocked();
        handler.deposit(roles(0, 0, 0, false, 0), 2 * one);
        handler.mint(roles(1, 1, 0, false, 0), 1e18);
        handler.depositWsgem(roles(2, 2, 0, false, 0), 2 * one);
        assertEq(handler.depositsBlocked(), blocked + 3, "deposits not blocked in deficit");
        uint256 served = handler.redeemsServed();
        handler.redeemToWsgem(roles(2, 2, 0, false, 0), 1e18);
        assertEq(handler.redeemsServed(), served + 1, "wsgem leg not live in deficit");
        assertLt(handler.lastRelease(), 1e18, "wsgem leg not pro-rata in deficit");
        assertGt(handler.lastRelease(), 0, "wsgem leg released nothing");
        handler.heal(type(uint256).max);
        assertEq(vault.deficit(), 0, "deficit not healed");
        assertEq(vault.convertToAssets(1e18), nav, "price not restored");

        // Gem pause: gem max* zero and gem legs blocked, the wsgem exit stays live.
        handler.gemPause();
        assertFalse(vault.gemTransfersAvailable(), "gem transfers available while paused");
        assertEq(vault.maxDeposit(a0), 0, "maxDeposit while gem paused");
        assertEq(vault.maxRedeem(a0), 0, "maxRedeem while gem paused");
        blocked = handler.depositsBlocked();
        handler.deposit(roles(0, 0, 0, false, 0), 2 * one);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked while gem paused");
        blocked = handler.redeemsBlocked();
        handler.redeem(roles(0, 0, 0, false, 0), 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked while gem paused");
        served = handler.redeemsServed();
        handler.redeemToWsgem(roles(1, 1, 0, false, 0), 1e17);
        assertEq(handler.redeemsServed(), served + 1, "wsgem exit not live while gem paused");
        handler.gemUnpause();

        // Vault banned: both wsgem legs and their max* go dark.
        handler.gemBanVault();
        assertEq(vault.maxRedeemToWsgem(a1), 0, "maxRedeemToWsgem while vault banned");
        assertEq(vault.maxDepositWsgem(a1), 0, "maxDepositWsgem while vault banned");
        blocked = handler.redeemsBlocked();
        handler.redeemToWsgem(roles(1, 1, 0, false, 0), 1e17);
        assertEq(handler.redeemsBlocked(), blocked + 1, "wsgem exit not blocked while vault banned");
        handler.gemUnbanVault();

        // Wsgem banned: it cannot pay gem out, so gem-out fails and the gem max* are zero.
        handler.gemBanWsgem();
        assertFalse(vault.gemTransfersAvailable(), "gem transfers available while wsgem banned");
        blocked = handler.redeemsBlocked();
        handler.redeem(roles(0, 0, 0, false, 0), 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked while wsgem banned");
        handler.gemUnbanWsgem();

        // Banned actor: its gem legs revert while max* stay as quoted; the probe skips it.
        handler.gemBanActor(roles(2, 0, 0, false, 0));
        blocked = handler.depositsBlocked();
        handler.deposit(roles(2, 2, 0, false, 0), 2 * one);
        assertEq(handler.depositsBlocked(), blocked + 1, "banned actor deposit not blocked");
        uint256 skipped = handler.probesSkipped();
        handler.probeMaxBoundary(roles(2, 0, 0, false, 0), 0, 0);
        assertEq(handler.probesSkipped(), skipped + 1, "probe not skipped for banned actor");
        handler.gemUnbanActor(roles(2, 0, 0, false, 0));

        // Thin liquidity: settle drains the pool, gem-out is blocked, a small refill leaves
        // the max* liquidity-capped and the probes check they are tight there.
        handler.settle();
        assertEq(gem.balanceOf(address(wsgem)), 0, "settle did not drain");
        blocked = handler.redeemsBlocked();
        handler.redeem(roles(0, 0, 0, false, 0), 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked when thin");
        handler.trickleLiquidity(one);
        assertLt(vault.maxRedeem(a0), vault.balanceOf(a0), "maxRedeem not liquidity-capped");
        uint256 run = handler.probesRun();
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 3, 0);
        handler.trickleLiquidity(one);
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 2, 0);
        assertEq(handler.probesRun(), run + 2, "liquidity probes");
        handler.refillLiquidity(1e6 * one);

        // Cooldown, market pause, oracle pause: gem-out / gem-in blocked, wsgem exit live.
        handler.setCooldown(1 days);
        assertEq(vault.maxRedeem(a0), 0, "maxRedeem during cooldown");
        blocked = handler.redeemsBlocked();
        handler.redeem(roles(0, 0, 0, false, 0), 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked in cooldown");
        handler.clearCooldown();
        handler.pauseMarket();
        blocked = handler.depositsBlocked();
        handler.deposit(roles(0, 0, 0, false, 0), 2 * one);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked while market paused");
        handler.reopenMarket();
        handler.pauseOracle();
        blocked = handler.redeemsBlocked();
        handler.withdraw(roles(0, 0, 0, false, 0), one);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked while oracle paused");
        served = handler.redeemsServed();
        handler.redeemToWsgem(roles(0, 0, 0, false, 0), 1e17);
        assertEq(handler.redeemsServed(), served + 1, "wsgem exit not live while oracle paused");
        handler.unpauseOracle();

        // Finite capacity: deposit and mint max* are tight at the cap; then cleared.
        handler.setCapacity(wsgem.totalSupply() + 3e18);
        assertLt(vault.maxDeposit(a0), type(uint256).max, "maxDeposit not finite");
        run = handler.probesRun();
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 0, 0);
        handler.setCapacity(wsgem.totalSupply() + 3e18);
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 1, 0);
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 4, 0);
        assertEq(handler.probesRun(), run + 3, "capacity probes");
        handler.clearCapacity();

        // Self-thinning probes: the pool is drained to three gem inside the probe, so the
        // liquidity-capped redeem and withdraw max* are checked tight from a healthy state.
        run = handler.probesRun();
        handler.probeMaxBoundary(roles(2, 0, 0, false, 0), 3, 3 * one + 1);
        handler.probeMaxBoundary(roles(2, 0, 0, false, 0), 2, 3 * one + 1);
        assertEq(handler.probesRun(), run + 2, "self-thinning probes");
        handler.refillLiquidity(1e6 * one);

        // maxDepositWsgem: 0 in a deficit (the zero deposit is a no-op), unlimited otherwise.
        handler.smelt(1e18);
        assertEq(vault.maxDepositWsgem(a0), 0, "maxDepositWsgem in deficit");
        uint256 supply = vault.totalSupply();
        run = handler.probesRun();
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 5, 0);
        assertEq(vault.totalSupply(), supply, "zero wsgem deposit minted shares");
        handler.heal(type(uint256).max);
        assertEq(vault.deficit(), 0, "second deficit not healed");
        handler.probeMaxBoundary(roles(0, 0, 0, false, 0), 5, 7 * one);
        assertGt(vault.totalSupply(), supply, "unlimited wsgem deposit not served");
        assertEq(handler.probesRun(), run + 2, "wsgem deposit probes");

        // Fees, an accrual with balances pinned, a donation, and a served withdraw.
        handler.setBpsin(10);
        handler.setBpsout(30);
        uint256 bal1 = vault.balanceOf(a1);
        uint256 nav0 = wsgem.navprice();
        handler.accrue(150);
        assertGt(wsgem.navprice(), nav0, "nav did not accrue");
        assertEq(vault.balanceOf(a1), bal1, "accrual moved a share balance");
        handler.donate(1e18);
        served = handler.redeemsServed();
        handler.withdraw(roles(1, 0, 0, false, 0), 3 * one); // above the one-wsgem exit floor at the poked nav
        assertEq(handler.redeemsServed(), served + 1, "withdraw not served");

        // NAV marks down with balances pinned; one-sided windows close only their own leg.
        nav0 = wsgem.navprice();
        bal1 = vault.balanceOf(a1);
        handler.markdown(0);
        assertLt(wsgem.navprice(), nav0, "nav did not mark down");
        assertEq(vault.balanceOf(a1), bal1, "markdown moved a share balance");
        handler.setMintWindow(false);
        assertEq(vault.maxDeposit(a0), 0, "maxDeposit with mint closed");
        assertGt(vault.maxRedeem(a0), 0, "maxRedeem with only mint closed");
        blocked = handler.depositsBlocked();
        handler.deposit(roles(0, 0, 0, false, 0), 2 * one);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked with mint closed");
        handler.setMintWindow(true);
        handler.setBurnWindow(false);
        assertEq(vault.maxRedeem(a0), 0, "maxRedeem with burn closed");
        assertGt(vault.maxDeposit(a0), 0, "maxDeposit with only burn closed");
        blocked = handler.redeemsBlocked();
        handler.redeem(roles(0, 0, 0, false, 0), 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "redeem not blocked with burn closed");
        handler.setBurnWindow(true);

        // Every op ran.
        assertGt(handler.depositOps(), 0, "deposit");
        assertGt(handler.mintOps(), 0, "mint");
        assertGt(handler.depositWsgemOps(), 0, "depositWsgem");
        assertGt(handler.redeemOps(), 0, "redeem");
        assertGt(handler.withdrawOps(), 0, "withdraw");
        assertGt(handler.redeemWsgemOps(), 0, "redeemToWsgem");
        assertGt(handler.transferOps(), 0, "transferShares");
        assertGt(handler.smeltOps(), 0, "smelt");
        assertGt(handler.healOps(), 0, "heal");
        assertGt(handler.donateOps(), 0, "donate");
        assertGt(handler.settleOps(), 0, "settle");
        assertGt(handler.refillOps(), 0, "refillLiquidity");
        assertGt(handler.trickleOps(), 0, "trickleLiquidity");
        assertGt(handler.setCooldownOps(), 0, "setCooldown");
        assertGt(handler.clearCooldownOps(), 0, "clearCooldown");
        assertGt(handler.pauseMarketOps(), 0, "pauseMarket");
        assertGt(handler.reopenMarketOps(), 0, "reopenMarket");
        assertGt(handler.pauseOracleOps(), 0, "pauseOracle");
        assertGt(handler.unpauseOracleOps(), 0, "unpauseOracle");
        assertGt(handler.accrueOps(), 0, "accrue");
        assertGt(handler.markdownOps(), 0, "markdown");
        assertGt(handler.setMintWindowOps(), 0, "setMintWindow");
        assertGt(handler.setBurnWindowOps(), 0, "setBurnWindow");
        assertGt(handler.setBpsinOps(), 0, "setBpsin");
        assertGt(handler.setBpsoutOps(), 0, "setBpsout");
        assertGt(handler.setCapacityOps(), 0, "setCapacity");
        assertGt(handler.clearCapacityOps(), 0, "clearCapacity");
        assertGt(handler.gemPauseOps(), 0, "gemPause");
        assertGt(handler.gemUnpauseOps(), 0, "gemUnpause");
        assertGt(handler.gemBanVaultOps(), 0, "gemBanVault");
        assertGt(handler.gemUnbanVaultOps(), 0, "gemUnbanVault");
        assertGt(handler.gemBanWsgemOps(), 0, "gemBanWsgem");
        assertGt(handler.gemUnbanWsgemOps(), 0, "gemUnbanWsgem");
        assertGt(handler.gemBanActorOps(), 0, "gemBanActor");
        assertGt(handler.gemUnbanActorOps(), 0, "gemUnbanActor");
        assertGt(handler.probeOps(), 0, "probeMaxBoundary");
        assertGt(handler.probesRun(), 8, "probes run");

        // And nothing was ever violated.
        invariant_NoViolations();
        invariant_BackingFairness();
        invariant_NoDanglingClaims();
        invariant_Spec();
    }
}

contract WsgemVaultDrainDec6InvariantTest is WsgemVaultDrainInvariantTest {
    function setUp() public override {
        gemDecimals = 6;
        initNavprice = 1.006e6;
        super.setUp();
    }
}
