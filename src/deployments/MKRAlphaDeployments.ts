import memd from "memd";
import { AccessControlManager } from "@0xc/hardhat/AccessControlManager/AccessControlManager";
import { Web3Client } from "dequanto/clients/Web3Client";
import { TEth } from "dequanto/models/TEth";
import { IPlatformAccounts } from "../platforms/IPlatform";
import { $require } from "dequanto/utils/$require";
import { StrataCDO } from "@0xc/hardhat/StrataCDO/StrataCDO";
import { ERC20Cooldown } from "@0xc/hardhat/ERC20Cooldown/ERC20Cooldown";
import { UnstakeCooldown } from "@0xc/hardhat/UnstakeCooldown/UnstakeCooldown";
import { $address } from "dequanto/utils/$address";
import { Constructor } from "dequanto/utils/types";
import { TrancheDepositor } from "@0xc/hardhat/TrancheDepositor/TrancheDepositor";
import { DeploymentsBase } from "./DeploymentsBase";
import { IStrategy } from "@0xc/hardhat/IStrategy/IStrategy";
import { IBeaconProxy } from "dequanto/contracts/deploy/proxy/ProxyDeployment";
import { MockMToken } from "@0xc/hardhat/MockMToken/MockMToken";
import { MockOracle } from "@0xc/hardhat/MockOracle/MockOracle";
import { MockDepositVault } from "@0xc/hardhat/MockDepositVault/MockDepositVault";
import { MockRedemptionVault } from "@0xc/hardhat/MockRedemptionVault/MockRedemptionVault";
import { MidasStrategy } from "@0xc/hardhat/MidasStrategy/MidasStrategy";
import { MultiRoundOracleAprPairProvider } from "@0xc/hardhat/MultiRoundOracleAprPairProvider/MultiRoundOracleAprPairProvider";
import { MockERC20 } from "@0xc/hardhat/MockERC20/MockERC20";
import { MidasCooldownRequestImpl } from "@0xc/hardhat/MidasCooldownRequestImpl/MidasCooldownRequestImpl";
import { MockUSDe } from "@0xc/hardhat/MockUSDe/MockUSDe";
import { AprPairFeed } from "@0xc/hardhat/AprPairFeed/AprPairFeed";

type TUnderlyingContracts = {
  mKRALPHA: MockMToken;
  oracle: MockOracle;
  depositVault: MockDepositVault;
  redemptionVault: MockRedemptionVault;

  USDC: MockERC20;
  USDT: MockERC20;
  USDS: MockERC20;
};

export class MKRAlphaDeployments extends DeploymentsBase<{
  Tokens: TUnderlyingContracts;
  Strategy: MidasStrategy;
}> {
  constructor(params: {
    client: Web3Client;
    deployer: TEth.EoAccount;
    owner?: TEth.IAccount;
    accounts?: IPlatformAccounts;
    deployments?: "throw" | "redeploy";
  }) {
    super({
      cdo: "mkralpha",
      ...params,
    });
  }

  async ensureFeedProvider() {
    let { oracle } = await this.ensureUnderlying();
    let acm = await this.ensureACM();

    const ROUND_DEPTH = 5;
    const APR_TARGET_STATIC = 0; // 0 disables static target; DYSAccounting.floorRate handles the floor

    const { contract: provider } = await this.ds.ensure(
      MultiRoundOracleAprPairProvider,
      {
        id: `${this.pfx}MultiRoundOracleAprPairProvider`,
        arguments: [acm.address, oracle.address, ROUND_DEPTH, APR_TARGET_STATIC],
      },
    );

    return {
      provider,
    };
  }

  @memd.deco.memoize({ perInstance: true })
  async ensureUnderlying(): Promise<
    {
      base: MockUSDe;
    } & TUnderlyingContracts
  > {
    let network = this.ds.client.network;
    if (network === "hardhat") {
      const USDC = await this.ds.ensureContract(MockERC20, {
        id: "USDC",
        arguments: ["USDC", 6],
      });
      const USDT = await this.ds.ensureContract(MockERC20, {
        id: "USDT",
        arguments: ["USDT", 6],
      });
      const USDS = await this.ds.ensureContract(MockERC20, {
        id: "USDS",
        arguments: ["USDS", 18],
      });

      const mKRALPHA = await this.ds.ensureContract(MockMToken);
      const oracle = await this.ds.ensureContract(MockOracle);
      const midasDepositVault = await this.ds.ensureContract(MockDepositVault, {
        arguments: [mKRALPHA.address, oracle.address],
      });
      const midasRedemptionVault = await this.ds.ensureContract(
        MockRedemptionVault,
        {
          arguments: [mKRALPHA.address, USDC.address, oracle.address],
        },
      );

      return {
        base: USDC as any,
        USDC,
        USDT,
        USDS,
        mKRALPHA,
        oracle,
        depositVault: midasDepositVault,
        redemptionVault: midasRedemptionVault,
      };
    }

    const { Tokens, mkralpha } = this.platform;

    const create = <T>(
      Ctor: Constructor<T>,
      symbolOrAddress: string | TEth.Address,
    ): T => {
      let address = $require.Address(
        Tokens[symbolOrAddress]?.address ?? symbolOrAddress,
      );
      let contract = new Ctor(address, this.ds.client);
      return contract;
    };

    return {
      base: create(MockERC20, "USDC") as any,
      mKRALPHA: create(MockMToken, "mKRALPHA"),

      USDC: create(MockERC20, "USDC"),
      USDT: create(MockERC20, "USDT"),
      USDS: create(MockERC20, "USDS"),

      oracle: create(MockOracle, mkralpha.oracle),
      depositVault: create(MockDepositVault, mkralpha.depositVault),
      redemptionVault: create(MockRedemptionVault, mkralpha.redemptionVault),
    };
  }

  async ensureUnstakeImplemenetations(): Promise<
    { token: TEth.Address; impl: IBeaconProxy }[]
  > {
    let { USDC, mKRALPHA, redemptionVault } = await this.ensureUnderlying();
    const { contractBeaconProxy: midasCooldownRequestImpl } =
      await this.ds.ensureWithBeacon(MidasCooldownRequestImpl, {
        id: `${this.pfx}CooldownRequestBeacon`,
        arguments: [USDC.address, mKRALPHA.address, redemptionVault.address],
        initialize: [$address.ZERO, $address.ZERO],
      });

    return [{ token: mKRALPHA.address, impl: midasCooldownRequestImpl }];
  }
  protected async ensureStrategy(
    cdo: StrataCDO,
    acm: AccessControlManager,
    erc20Cooldown: ERC20Cooldown,
    unstakeCooldown: UnstakeCooldown,
  ): Promise<{ strategy: MidasStrategy }> {
    const {
      USDC,
      USDT,
      USDS,
      mKRALPHA,
      depositVault,
      redemptionVault,
      oracle,
    } = await this.ensureUnderlying();
    const { contract: strategy } = await this.ds.ensureWithProxy(
      MidasStrategy,
      {
        id: `${this.pfx}MidasStrategy`,
        arguments: [
          USDC.address,
          mKRALPHA.address,
          depositVault.address,
          redemptionVault.address,
          oracle.address,
        ],
        initialize: [
          this.owner.address,
          acm.address,
          cdo.address,
          erc20Cooldown.address,
          unstakeCooldown.address,
          [USDT.address, USDS.address],
        ],
      },
    );
    return { strategy };
  }
  async configureCooldowns(strategy: IStrategy): Promise<void> {}
  async configureDepositor(depositor: TrancheDepositor) {
    let { USDC } = await this.ensureUnderlying();
    let { cdo, jrtVault } = await this.ensureCDO();

    let status = await depositor.tranches(jrtVault.address, USDC.address);
    if (status == false) {
      await depositor.$receipt().addCdo(this.owner, cdo.address);
    }

    return depositor;
  }

  protected override async configureAprFeed(feed: AprPairFeed) {
    // No spread configuration needed for MultiRoundOracleAprPairProvider.
    // The static target APR and round depth are configured in ensureFeedProvider.
  }
}
