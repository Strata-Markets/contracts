import { UAction } from 'atma-utest';
import { Web3ClientFactory } from 'dequanto/clients/Web3ClientFactory';
import { ChainAccountService } from 'dequanto/ChainAccountService';
import { EoAccount } from 'dequanto/models/TAccount';
import { l } from 'dequanto/utils/$logger';
import { PlatformFactory } from './PlatformFactory';
import { SymbioticDeployments } from '@s/deployments/SymbioticDeployments';

UAction.create({

    // npx atma act tasks/deploySymbiotic.act.ts -q "deploy" --chain eth [--appAdapter 0x..]
    //
    // Deploys the shared OracleAdapter + InsuranceMiddleware, registers the Chainlink feeds
    // (from src/constants.ts) and the covered markets (from src/platforms/symbiotic/SymbioticConfig.ts).
    // The AppAdapter is deployed on the Symbiotic side; pass it via --appAdapter or set it in the config.
    async 'deploy'() {
        const config = await PlatformFactory.ConfigLoader.fetch();
        const platform = config.$get('chain') ?? 'eth';
        const client = await Web3ClientFactory.getAsync(platform);
        const { network } = client;

        const deployer = await ChainAccountService.get(`${network}/deployer`) as EoAccount;
        const owner = await ChainAccountService.get(`safe/${network}/strata`);

        const depl = new SymbioticDeployments({
            client,
            deployer,
            owner,
            appAdapter: config.$get('appAdapter'),
            deployments: config.$get('deployments'),
        });

        const { middleware, oracle } = await depl.ensureDeployment();

        l`OracleAdapter:     ${oracle.address}`;
        l`InsuranceMiddleware: ${middleware.address}`;
    },
});
