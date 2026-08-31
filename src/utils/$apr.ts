import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $number } from 'dequanto/utils/$number';
import { $require } from 'dequanto/utils/$require';

const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
export namespace $apr {
    const DECIMALS = 12;
    const SECONDS_PER_YEAR = BigInt(365 * 24 * 60 * 60);
    const ONE_APR = BigInt(1e12);

    export function calcAprFromExchangeRates (
        p0: number | bigint,
        p1: number | bigint,
        t0: number | bigint,
        t1: number | bigint
    ) {
        $require.lte(t0, t1, `TimeArrow`);
        const dt = BigInt(t1) - BigInt(t0);
        if (dt == 0n || p1 == p0 || p0 == 0) {
            return 0;
        }
        const p0_ = typeof p0 === 'number'
            ? $bigint.toWei(p0, 6)
            : p0;
        const p1_ = typeof p1 === 'number'
            ? $bigint.toWei(p1, 6)
            : p1;

        const apr = (p1_ - p0_) * SECONDS_PER_YEAR * ONE_APR / p0_ / dt;
        return $bigint.toEther(apr, 12);
    }

    export function toApy (apr: number | bigint) {
        if (typeof apr === 'bigint') {
            apr = $bigint.toEther(apr, 12);
        }
        if (apr > 1) apr /= 100;
        let apy = (1 + apr / 365) ** 365 - 1;
        apy *= 100;
        return $number.round(apy, 2, 'round');
    }

    export function toWei (apr: number) {
        return Number($bigint.toWei(apr, DECIMALS));
    }

    export function toEther (apr: number) {
        return $bigint.toEther(apr, DECIMALS);
    }

    export function calcAprSrt (params: {
        aprs: { target: number, base: number},
        risk: [number, number, number],
        tvls: { jrt: number, srt: number },
    }) {
        let { jrt, srt } = params.tvls;
        let { target, base } = params.aprs;
        let [x, y, k ] = params.risk;

        let tvlRatio = srt / (jrt + srt);
        let risk = x + y * tvlRatio ** k;
        let aprSrt1 = base * (1 - risk);
        let aprSrt = Math.max(target, aprSrt1);
        return aprSrt;
    }

    export function calcPrice(params: {
        price: number | bigint,
        decimals?: number,
        apr: number | bigint,
        dt: number | string
    }) {
        let dt = typeof params.dt === 'string'
            ? $date.parseTimespan(params.dt, { get: 's' })
            : params.dt;
        let apr = typeof params.apr === 'bigint' ? params.apr : $bigint.toWei(params.apr, 12);
        let gainFactor = apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR);
        let price = typeof params.price === 'number'
            ? $bigint.toWei(params.price, params.decimals ?? 18)
            : params.price;

        let nextPrice = price * (10n**12n + gainFactor) / 10n**12n;
        return nextPrice
    }

    export function calcAprJrt (params: {
        aprs: { target: number, base: number},
        risk: [number, number, number],
        tvls: { jrt: number, srt: number },
    }) {
        let { jrt, srt } = params.tvls;
        let { base } = params.aprs;
        let aprSrt = calcAprSrt(params);
        let tvlRatioSrt = srt / (jrt + srt);
        let tvlRatioJrt = jrt / (jrt + srt);

        let aprJrtSpread = (base - aprSrt) * tvlRatioSrt / tvlRatioJrt;
        let aprJrt = base + aprJrtSpread;
        return aprJrt;
    }

    export function final ($: number, apr: number, dt: string = '1year') {
        return $ + Yield($, apr, dt);
    }
    export function Yield ($: number, apr: number, dt: string = '1year') {
        const seconds = $date.parseTimespan(dt, { get:'s' });
        const year = 365 * 24 * 60 * 60;
        return $ * apr * seconds / year;
    }

    export function value ($: number) {
        return new AprChain($);
    }

    class AprChain {
        constructor (public $: number) {

        }
        next (apr: number, months: number = 12) {
            this.$ = this.$ + this.$ * apr * months /12;
            return this.$;
        }
        calc (apr: number, months: number = 12) {
            return this.$ + this.$ * apr * months /12;
        }
    }

    export class AccountingMath {

        constructor (public store: {
            aprs: { target: number, base: number},
            risk: [number, number, number],
            tvls: { jrt: number, srt: number },
        }) {

        }

        next (months: number) {
            let srtApr = calcAprSrt(this.store);
            let jrtApr = calcAprJrt(this.store);

            let { srt, jrt } = this.store.tvls;
            jrt = final(jrt, jrtApr, `${months}months`);
            srt = final(srt, srtApr, `${months}months`);

            this.store.tvls = { jrt, srt };
            return this;
        }

        tvlsArr (): [number, number] {
            return [ this.store.tvls.jrt, this.store.tvls.srt  ];
        }
    }
}
