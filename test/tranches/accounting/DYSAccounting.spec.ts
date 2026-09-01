import { UTest } from "atma-utest";
import { $hh } from "../utils/$hh";
import { $bigint } from "dequanto/utils/$bigint";
import { $require } from "dequanto/utils/$require";
import { $date } from "dequanto/utils/$date";
import { l } from "dequanto/utils/$logger";
import { HardhatProvider } from "dequanto/hardhat/HardhatProvider";
import { DYSAccounting } from "@0xc/hardhat/DYSAccounting/DYSAccounting";
import { $apr } from "@s/utils/$apr";

// Must explicitly override ContractVersions.accounting to 'dys';
// $hh.Test defaults to 'discrete' via ??= which would override Tranches config.
const test = $hh.create("mkralpha", {
  cdoInfo: { ContractVersions: { accounting: "dys" } },
});

const contracts = await test.deploy();
// eslint-disable-next-line prefer-destructuring
const client = test.client;

// Re-instantiated inside setup() so all DYS-specific functions are available
let accounting: DYSAccounting;

const TOLERANCE_WEI = 10n ** 12n; // 1 millionth of a USDC

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

let mockCdo: any;

async function setup() {
  await test.reset();
  const hh = new HardhatProvider();

  const { contract } = await hh.deployCode(
    `
        contract MockCDO {
            uint256 public _nav = 0;
            function setTotalAssets(uint256 amount) external { _nav = amount; }
            function increment(int256 amount) external {
                _nav = amount > 0
                    ? _nav + uint256(amount)
                    : _nav - uint256(-amount);
            }
            function totalStrategyAssets() public view returns (uint256) { return _nav; }
            function totalStrategyAssets(uint256, uint256) public view returns (uint256) { return _nav; }
            function totalStrategyAssetsSnapshot (uint256, uint256) public view returns (uint256, uint256, uint256, uint256) {
              return (_nav, block.timestamp, _nav, block.timestamp);
            }
        }
    `,
    { client },
  );

  mockCdo = contract;

  // Re-instantiate as a fresh DYSAccounting bound to the deployed address
  // (the base IAccounting from the deployment does not expose DYS state vars)
  accounting = new DYSAccounting(contracts.accounting.address, client);

  // Redirect accounting to use mock CDO
  await accounting.storage.$set("cdo", mockCdo.address);

  // Give mockCdo ETH so it can call onlyCDO methods
  await client.debug.setBalance(mockCdo.address, 10n ** 18n);
  await client.debug.impersonateAccount(mockCdo.address);
}

async function setNav(amount: number) {
  await mockCdo.$receipt().setTotalAssets(mockCdo, toWei(amount));
}

async function balanceFlow(
  jrtIn: number,
  jrtOut: number,
  srtIn: number,
  srtOut: number,
) {
  const diff = jrtIn + srtIn - jrtOut - srtOut;
  await mockCdo.$receipt().increment(mockCdo, $bigint.toWei(diff));
  await accounting
    .$receipt()
    .updateBalanceFlow(
      mockCdo,
      toWei(jrtIn),
      toWei(jrtOut),
      toWei(srtIn),
      toWei(srtOut),
    );
}

async function updateAccounting() {
  await accounting.$receipt().updateAccounting(mockCdo);
}

function toWei(n: number) {
  return $bigint.toWei(n, 6);
}
function toEth(n: bigint) {
  return $bigint.toEther(n, 6);
}

function assertClose(
  fact: bigint,
  expected: bigint,
  toleranceWei: bigint,
  msg: string,
) {
  const diff = fact > expected ? fact - expected : expected - fact;
  if (diff > toleranceWei) {
    throw new Error(
      `${msg}: fact=${toEth(fact)}, expected≈${toEth(expected)}, diff=${toEth(
        diff,
      )}`,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

UTest.create({
  async $after() {
    await client.debug.stopImpersonatingAccount(mockCdo.address);
    await test.wipe();
  },

  // ── Asset-time accrual ──────────────────────────────────────────────────
  "Asset-time accrual": {
    async "srtNavTime accumulates correctly over 1 day"() {
      await setup();
      await setNav(0);
      // 500 JRT + 500 SRT deposits
      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      const srtBefore = await accounting.srtNavTime();
      $require.eq(srtBefore, 0n, "srtNavTime should start at 0");

      // Mine 1 day — asset-time accrues lazily on next state change
      await test.mine("1day");

      // Trigger accrue via balanceFlow (no-op flow)
      await balanceFlow(0, 0, 0, 0);

      const srtAfter = await accounting.srtNavTime();
      const navTimeAfter = await accounting.navTime();

      const ONE_DAY_S = BigInt($date.parseTimespan("1day", { get: "s" }));
      const expectedSrtNavTime = toWei(500) * ONE_DAY_S;
      const expectedNavTime = toWei(1000) * ONE_DAY_S;

      l`srtNavTime: cyan<${srtAfter}> expected≈${expectedSrtNavTime}`;
      // Allow ±10s of timing drift (hardhat block timing is approximate)
      const tolerance = toWei(500) * 10n;
      assertClose(srtAfter, expectedSrtNavTime, tolerance, "srtNavTime");
      assertClose(navTimeAfter, expectedNavTime, toWei(1000) * 10n, "navTime");
    },

    async "srtNavTime resets to 0 after reconciliation"() {
      await setup();
      await setNav(0);
      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      await test.mine("1day");
      // Trigger reconciliation: navT1 ≠ navT0
      await setNav(1050);
      await updateAccounting();

      const srtNavTime = await accounting.srtNavTime();
      const navTime = await accounting.navTime();
      $require.eq(
        srtNavTime,
        0n,
        "srtNavTime should reset after reconciliation",
      );
    },

    async "lastAccrual updates on every state change"() {
      await setup();
      await setNav(0);
      await balanceFlow(500, 0, 500, 0);

      const t0 = await accounting.lastAccrual();
      await test.mine("1day");
      await balanceFlow(0, 0, 0, 0);
      const t1 = await accounting.lastAccrual();

      $require.gt(t1, t0, "lastAccrual should advance after balanceFlow");
      const dt = Number(t1 - t0);
      const oneDayS = $date.parseTimespan("1day", { get: "s" });
      $require.True(
        dt >= oneDayS - 2 && dt <= oneDayS + 5,
        `dt should be ~1day, got ${dt}s`,
      );
    },
  },

  // ── Projection (no oracle update) ────────────────────────────────────────
  "Projection (navT0 == navT1)": {
    async "srtPnLProjected accumulates when no oracle update"() {
      await setup();
      await setNav(0);

      // Set APRs: target=5%, base=15%
      const { feed } = test.tranches;
      const ts = (await client.getBlock("latest")).timestamp;
      await feed
        .$receipt()
        .updateRoundData(test.deployer, $apr.toWei(0.05), $apr.toWei(0.15), ts);
      await accounting.$receipt().onAprChanged(test.deployer);

      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      const projectedBefore = await accounting.srtPnLProjected();
      $require.eq(projectedBefore, 0n, "srtPnLProjected starts at 0");

      // Mine 1 year, no NAV change — triggers projection
      await test.mine("1year");
      // Same NAV → projection path
      await updateAccounting();

      const projectedAfter = await accounting.srtPnLProjected();
      l`srtPnLProjected after 1y projection: cyan<${toEth(projectedAfter)}>`;
      // Should be positive (SRT earned something via projection)
      $require.gt(projectedAfter, 0n, "srtPnLProjected should be > 0 after 1y");

      // Senior NAV should have increased (projection)
      const srtNav = await accounting.srtNav();
      $require.gt(srtNav, toWei(500), "srtNav should grow during projection");
    },
  },

  // ── Reconciliation true-up ────────────────────────────────────────────────
  "Reconciliation true-up": {
    async "Senior PnL is reallocated based on DYS formula"() {
      await setup();
      await setNav(0);

      // Set APR: target=0 (DYS style), base=10%
      const { feed } = test.tranches;
      const ts = (await client.getBlock("latest")).timestamp;
      await feed
        .$receipt()
        .updateRoundData(test.deployer, 0n, $apr.toWei(0.1), ts);
      await accounting.$receipt().onAprChanged(test.deployer);

      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      // Mine 1 day (1 epoch)
      await test.mine("1day");

      // Trigger projection (no NAV change)
      await updateAccounting();

      const srtProjected = await accounting.srtPnLProjected();
      const srtNavBeforeReconcile = await accounting.srtNav();
      const jrtNavBeforeReconcile = await accounting.jrtNav();
      l`Before reconcile: srtNav=${toEth(
        srtNavBeforeReconcile,
      )}, jrtNav=${toEth(jrtNavBeforeReconcile)}, srtPnLProjected=${toEth(
        srtProjected,
      )}`;

      // Now reconcile: +100 USDC gain (10%)
      await setNav(1100);
      await updateAccounting();

      const srtNavAfter = await accounting.srtNav();
      const jrtNavAfter = await accounting.jrtNav();
      const reserveNavAfter = await accounting.reserveNav();
      const pnlProjectedAfter = await accounting.srtPnLProjected();

      l`After reconcile: srtNav=${toEth(srtNavAfter)}, jrtNav=${toEth(
        jrtNavAfter,
      )}, reserve=${toEth(reserveNavAfter)}`;

      // NAV invariant: jrt + srt + reserve == navT1
      const nav1 = toWei(1100);
      const sumAfter = jrtNavAfter + srtNavAfter + reserveNavAfter;
      assertClose(
        sumAfter,
        nav1,
        TOLERANCE_WEI,
        "NAV invariant jrt+srt+reserve==navT1",
      );

      // srtPnLProjected resets to 0 after reconciliation
      $require.eq(
        pnlProjectedAfter,
        0n,
        "srtPnLProjected should reset after reconciliation",
      );

      // SRT should have gained (positive PnL with 50/50 split)
      $require.gt(
        srtNavAfter,
        toWei(500),
        "SRT should gain after positive reconciliation",
      );
    },

    async "NAV invariant holds for multiple epochs"() {
      await setup();
      await setNav(0);

      const { feed } = test.tranches;
      const ts = (await client.getBlock("latest")).timestamp;
      await feed
        .$receipt()
        .updateRoundData(test.deployer, 0n, $apr.toWei(0.12), ts);
      await accounting.$receipt().onAprChanged(test.deployer);

      await balanceFlow(600, 0, 400, 0);
      await setNav(1000);

      for (let epoch = 1; epoch <= 3; epoch++) {
        await test.mine("1day");
        // Projection
        await updateAccounting();
        // Reconcile with +5 gain per epoch
        await setNav(1000 + epoch * 10);
        await updateAccounting();

        const jrt = await accounting.jrtNav();
        const srt = await accounting.srtNav();
        const reserve = await accounting.reserveNav();
        const nav = await accounting.nav();

        l`Epoch ${epoch}: jrt=${toEth(jrt)} srt=${toEth(srt)} reserve=${toEth(
          reserve,
        )} nav=${toEth(nav)}`;
        assertClose(
          jrt + srt + reserve,
          nav,
          TOLERANCE_WEI,
          `NAV invariant epoch ${epoch}`,
        );
      }
    },
  },

  // ── Senior floor (rate-based) ──────────────────────────────────────────────
  "Rate-based Senior floor": {
    async "floor kicks in when SRT PnL would be worse than -0.1%/day"() {
      await setup();
      await setNav(0);

      // Set floor rate to 0.1%/day (0.001e18)
      const FLOOR_RATE = BigInt(0.001e18); // 0.1%/day
      await (accounting as any).$receipt().setFloorRate(test.deployer, FLOOR_RATE);

      // Confirm floorRate is now set
      const floorRate = await (accounting as any).floorRate();
      $require.eq(
        floorRate,
        FLOOR_RATE,
        "floorRate should be 0.001e18 after setting floor",
      );

      // 100 JRT / 900 SRT — very high SRT ratio → large risk premium → small srt pnl
      await balanceFlow(100, 0, 900, 0);
      await setNav(1000);

      await test.mine("1day");
      await updateAccounting(); // projection

      // Severe loss: -5% total loss
      await setNav(950);
      await updateAccounting();

      const srtNavAfter = await accounting.srtNav();
      const jrtNavAfter = await accounting.jrtNav();
      const reserveNavAfter = await accounting.reserveNav();
      const nav = await accounting.nav();

      l`After loss reconcile: srtNav=${toEth(srtNavAfter)}, jrtNav=${toEth(
        jrtNavAfter,
      )}`;

      // NAV invariant must hold
      assertClose(
        jrtNavAfter + srtNavAfter + reserveNavAfter,
        nav,
        TOLERANCE_WEI,
        "NAV invariant after floor",
      );

      // Floor: -36.5%/yr * 1day / 365 * 900 USDC = 0.9 USDC max loss
      // SRT NAV should be >= ~900 - 0.9 = 899.1 (minus any projection added)
      const minSrtNav = toWei(898); // generous tolerance for projection effects
      $require.gte(
        srtNavAfter,
        minSrtNav,
        "SRT NAV should be protected by floor",
      );
    },

    async "floor does not bind when loss is within -0.1%/day"() {
      await setup();
      await setNav(0);

      // Set floor rate to 0.1%/day (0.001e18)
      const FLOOR_RATE = BigInt(0.001e18);
      await (accounting as any).$receipt().setFloorRate(test.deployer, FLOOR_RATE);

      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      await test.mine("1day");
      await updateAccounting(); // projection

      // Small positive gain (floor irrelevant)
      await setNav(1002);
      await updateAccounting();

      const jrt = await accounting.jrtNav();
      const srt = await accounting.srtNav();
      const reserve = await accounting.reserveNav();
      const nav = await accounting.nav();

      assertClose(
        jrt + srt + reserve,
        nav,
        TOLERANCE_WEI,
        "NAV invariant after small gain (floor not binding)",
      );
      $require.gt(srt, toWei(500), "SRT should gain when no floor needed");
      $require.gt(jrt, toWei(500), "JRT should gain when no floor needed");
    },

    async "floor scales with epoch duration (2-day epoch = 2x loss cap)"() {
      await setup();
      await setNav(0);

      // Set floor rate to 0.1%/day (0.001e18)
      const FLOOR_RATE = BigInt(0.001e18);
      await (accounting as any).$receipt().setFloorRate(test.deployer, FLOOR_RATE);

      await balanceFlow(100, 0, 900, 0);
      await setNav(1000);
      await updateAccounting();
      console.log('srtNav', await accounting.srtNav());
      console.log('windowStartSrtNav', await accounting.windowStartSrtNav());

      // Mine 2 days — floor should allow 2x loss (-0.2% of avgSrAssets)
      await test.mine("2days");
      await updateAccounting(); // projection

      // Severe loss: -5%
      await setNav(950);
      await updateAccounting();

      const srtNavAfter = await accounting.srtNav();
      const jrtNavAfter = await accounting.jrtNav();
      const reserveNavAfter = await accounting.reserveNav();
      const nav = await accounting.nav();

      assertClose(
        jrtNavAfter + srtNavAfter + reserveNavAfter,
        nav,
        TOLERANCE_WEI,
        "NAV invariant 2-day epoch",
      );

      // Floor for 2 days: 0.2% * 900 = 1.8 USDC max loss → SRT >= 900 - 1.8 = 898.2
      const minSrtNav2Day = toWei(898);
      $require.lt(
        srtNavAfter,
        toWei(900 - 1),
        "SRT should realize loss",
      );
      $require.gte(
        srtNavAfter,
        minSrtNav2Day,
        "SRT protected by 2-day scaled floor",
      );

      // Floor for 2 days covered by 0.2% SRT loss
      const minJrtNav2Day = toWei(100 - 50 + (0.002 * 900));
      $require.gte(
        jrtNavAfter,
        minJrtNav2Day,
        "JRT covered by 2-day SRT scaled floor",
      );
    },
  },

  // ── Edge cases ────────────────────────────────────────────────────────────
  "Edge cases": {
    async "reconciliation with zero navTime falls back gracefully"() {
      await setup();
      await setNav(0);
      await balanceFlow(500, 0, 500, 0);

      // Immediately reconcile (navTime == 0 because no time has passed)
      await setNav(1050);
      await updateAccounting();

      const srtNav = await accounting.srtNav();
      const jrtNav = await accounting.jrtNav();
      const reserveNav = await accounting.reserveNav();
      const nav = await accounting.nav();

      l`Zero navTime reconcile: srtNav=${toEth(srtNav)}, jrtNav=${toEth(
        jrtNav,
      )}`;
      assertClose(
        jrtNav + srtNav + reserveNav,
        nav,
        TOLERANCE_WEI,
        "NAV invariant with zero navTime",
      );
    },

    async "deposit during epoch updates asset-time before balance change"() {
      await setup();
      await setNav(0);
      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      await test.mine("12hours");

      // Midway deposit of 200 JRT
      await balanceFlow(200, 0, 0, 0);
      await setNav(1200);

      const srtNavTime = await accounting.srtNavTime();
      const navTime = await accounting.navTime();

      l`navTime after midway deposit: cyan<${navTime}>`;
      // navTime should reflect the 500+500 for 12h, not 500+700 for the whole period
      $require.gt(
        navTime,
        0n,
        "navTime should be positive after midway deposit",
      );
      $require.gt(
        srtNavTime,
        0n,
        "srtNavTime should be positive after midway deposit",
      );
    },

    async "accrueFee calls _accrueAssetTime before modifying NAVs"() {
      await setup();
      await setNav(0);

      const { feed } = test.tranches;
      const ts = (await client.getBlock("latest")).timestamp;
      await feed
        .$receipt()
        .updateRoundData(test.deployer, 0n, $apr.toWei(0.1), ts);
      await accounting.$receipt().onAprChanged(test.deployer);

      await balanceFlow(500, 0, 500, 0);
      await setNav(1000);

      await test.mine("1day");

      const srtNavTimeBefore = await accounting.srtNavTime();

      // accrueFee for SRT (isJrt=false, 10 USDC fee)
      await accounting.$receipt().accrueFee(mockCdo, false, toWei(10));

      const srtNavTimeAfter = await accounting.srtNavTime();
      // srtNavTime should have accrued before the fee was applied
      $require.gt(
        srtNavTimeAfter,
        srtNavTimeBefore,
        "srtNavTime should accrue before fee deduction",
      );

      const srtNav = await accounting.srtNav();
      // Fee (50% retention means 50% goes to reserve): srtNav should be < 500
      $require.lt(
        srtNav,
        toWei(500),
        "srtNav should decrease after fee accrual",
      );
    },
  },
});
