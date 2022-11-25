#!/usr/bin/env node
import 'source-map-support/register';
import EmrEksStack from '../lib/emr-eks-blueprint-stack';
import { App } from 'aws-cdk-lib';
import { EmrEksTeamProps } from '../lib/teams/emrEksTeam';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';

const app = new App();
const account = '314704651063';
const region = 'eu-west-1';


const executionRolePolicyStatement: PolicyStatement[] = [
  new PolicyStatement({
    resources: ['*'],
    actions: ['s3:*'],
  }),
  new PolicyStatement({
    resources: ['*'],
    actions: ['glue:*'],
  }),
  new PolicyStatement({
    resources: ['*'],
    actions: [
      'logs:*',
    ],
  }),
];

const dataTeam: EmrEksTeamProps = {
  name: 'dataTeam',
  virtualClusterName: 'blueprintjob',
  virtualClusterNamespace: 'blueprintjob',
  createNamespace: true,
  excutionRoles: [
    {
      excutionRoleIamPolicyStatement: executionRolePolicyStatement,
      excutionRoleName: 'myBlueprintExecRole'
    }
  ]
};

const props = {
  env: { account, region },
  dataTeams: [dataTeam],
  clusterVpc: 'vpc-068459402d2e42fe0'
};

new EmrEksStack().build(app, 'BlueprintRefactoring', props);
