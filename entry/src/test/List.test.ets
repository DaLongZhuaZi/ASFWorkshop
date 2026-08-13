import localUnitTest from './LocalUnit.test';
import dependencyContainerTest from './DependencyContainer.test';
import systemIntegrationTest from './SystemIntegrationFacade.test';
import workflowDefinitionTest from './WorkflowDefinitionFacade.test';
import steamArkStateServiceTest from './SteamArkStateService.test';
import steamArkFarmingServiceTest from './SteamArkFarmingService.test';
import steamArkNetworkAdapterTest from './SteamArkNetworkAdapter.test';
import steamArkHttpAdapterTest from './SteamArkHttpAdapter.test';
import steamArkNetworkProbeTest from './SteamArkNetworkProbe.test';
import steamArkCmRuntimeTest from './SteamArkCmRuntime.test';
import steamArkSensitiveActionGateTest from './SteamArkSensitiveActionGate.test';
import steamArkSensitiveActionConfirmationTest from './SteamArkSensitiveActionConfirmation.test';
import steamArkWidgetStateStoreTest from './SteamArkWidgetStateStore.test';

export default function testsuite() {
  localUnitTest();
  dependencyContainerTest();
  systemIntegrationTest();
  workflowDefinitionTest();
  steamArkStateServiceTest();
  steamArkFarmingServiceTest();
  steamArkNetworkAdapterTest();
  steamArkHttpAdapterTest();
  steamArkNetworkProbeTest();
  steamArkCmRuntimeTest();
  steamArkSensitiveActionGateTest();
  steamArkSensitiveActionConfirmationTest();
  steamArkWidgetStateStoreTest();
}
