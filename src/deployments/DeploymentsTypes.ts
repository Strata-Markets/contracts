import { EthenaDeployments } from './EthenaDeployments';
import { FigureDeployments } from './FigureDeployments';
import { SpkMhyperIsoDeployments } from './SpkMhyperIsoDeployments';
import { MHyperDeployments } from './MHyperDeployments';
import { MKRAlphaDeployments } from './MKRAlphaDeployments';
import { MM1UsdDeployments } from './MM1UsdDeployments';
import { MROXDeployments } from './MROXDeployments';
import { NeutrlDeployments } from './NeutrlDeployments';
import { SaturnDeployments } from './SaturnDeployments';
import { NestOpalDeployments } from './NestOpalDeployments';

export namespace DeploymentsTypes {
    export type CDOs = {
        ethena: EthenaDeployments;
        figure: FigureDeployments;
        spkMhyperIso: SpkMhyperIsoDeployments;
        neutrl: NeutrlDeployments;
        mhyper: MHyperDeployments;
        mkralpha: MKRAlphaDeployments;
        mm1usd: MM1UsdDeployments;
        mrox: MROXDeployments;
        saturn: SaturnDeployments;
        nestopal: NestOpalDeployments;
    };

    export const Tranches = {
        ethena: EthenaDeployments,
        figure: FigureDeployments,
        spkMhyperIso: SpkMhyperIsoDeployments,
        neutrl: NeutrlDeployments,
        mhyper: MHyperDeployments,
        mkralpha: MKRAlphaDeployments,
        mm1usd: MM1UsdDeployments,
        mrox: MROXDeployments,
        saturn: SaturnDeployments,
        nestopal: NestOpalDeployments,
    };
}
