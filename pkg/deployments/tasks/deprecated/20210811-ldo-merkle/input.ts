import Task, { TaskMode } from '../../../src/task';

export type MerkleRedeemDeployment = {
  Vault: string;
  ldoToken: string;
};

const Vault = new Task('20210418-vault', TaskMode.READ_ONLY);

export default {
  mainnet: {
    Vault,
    ldoToken: '0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32',
  },
};
