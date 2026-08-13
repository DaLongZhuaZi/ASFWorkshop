import { describe, beforeEach, it, expect } from '@ohos/hypium';
import {
  IActionExecutor,
  NGFActionResult,
  NGFWorkflowDefinition,
  NGFWorkflowParallelGroup,
  NGFWorkflowStepDefinition,
  ngfActionExecutorFacade,
  ngfWorkflowDefinitionFacade,
  WorkflowDefinitionFacade
} from 'ngf_framework';

export default function workflowDefinitionTest() {
  describe('WorkflowDefinitionFacadeTest', () => {

    beforeEach(() => {
      // Unregister any existing test workflows to ensure clean state
      ngfWorkflowDefinitionFacade.unregisterWorkflow('test_workflow');
      ngfWorkflowDefinitionFacade.unregisterWorkflow('parallel_workflow');
      ngfWorkflowDefinitionFacade.unregisterWorkflow('timeout_workflow');
    });

    it('testSerialExecution', 0, async () => {
      const step1 = new NGFWorkflowStepDefinition('step1', 'wait', '{"waitMs":0}', null, null);
      const step2 = new NGFWorkflowStepDefinition('step2', 'wait', '{"waitMs":0}', null, null);
      const definition = new NGFWorkflowDefinition('test_workflow', 'serial workflow test', [step1, step2]);
      
      ngfWorkflowDefinitionFacade.registerWorkflow(definition);
      
      const result = await ngfWorkflowDefinitionFacade.executeWorkflow('test_workflow', '{}');
      
      expect(result.success).assertTrue();
      expect(result.stepResults.length).assertEqual(2);
      expect(result.stepResults[0].stepName).assertEqual('step1');
      expect(result.stepResults[1].stepName).assertEqual('step2');
    });

    it('testParallelExecution', 0, async () => {
      const pStep1 = new NGFWorkflowStepDefinition('p_step1', 'wait', '{"waitMs":100}', null, null);
      const pStep2 = new NGFWorkflowStepDefinition('p_step2', 'wait', '{"waitMs":50}', null, null);
      
      const pGroup = new NGFWorkflowParallelGroup('pGroup1', [pStep1, pStep2], null);
      
      const definition = new NGFWorkflowDefinition('parallel_workflow', 'parallel workflow test', [], [pGroup]);
      const fakeExecutor = new DeterministicParallelActionExecutor(2);
      const testFacade = new WorkflowDefinitionFacade(fakeExecutor);
      testFacade.registerWorkflow(definition);
      const result = await testFacade.executeWorkflow('parallel_workflow', '{}');
      
      expect(result.success).assertTrue();
      expect(result.stepResults.length).assertEqual(2);
      expect(fakeExecutor.startedCount).assertEqual(2);
      expect(fakeExecutor.maxConcurrentCount).assertEqual(2);
      expect(fakeExecutor.releasedAfterAllStarted).assertTrue();
    });

    it('testStepTimeout', 0, async () => {
      const step = new NGFWorkflowStepDefinition('timeout_step', 'wait', '{"waitMs":200}', null, 50);
      const definition = new NGFWorkflowDefinition('timeout_workflow', 'step timeout test', [step]);
      ngfWorkflowDefinitionFacade.registerWorkflow(definition);
      
      const result = await ngfWorkflowDefinitionFacade.executeWorkflow('timeout_workflow', '{}');
      
      expect(result.success).assertFalse();
      expect(result.stepResults.length).assertEqual(1);
      expect(result.stepResults[0].success).assertFalse();
    });

    it('testParallelGroupTimeout', 0, async () => {
      const pStep1 = new NGFWorkflowStepDefinition('p_step1', 'wait', '{"waitMs":200}', null, null);
      // Group timeout is 50ms, the step takes 200ms
      const pGroup = new NGFWorkflowParallelGroup('pGroup1', [pStep1], 50);
      
      const definition = new NGFWorkflowDefinition('parallel_timeout_workflow', 'parallel timeout test', [], [pGroup]);
      ngfWorkflowDefinitionFacade.registerWorkflow(definition);
      
      const result = await ngfWorkflowDefinitionFacade.executeWorkflow('parallel_timeout_workflow', '{}');
      
      expect(result.success).assertFalse();
    });

    it('testActionOutputEscapesSpecialCharacters', 0, async () => {
      const contextJson = '{"title":"A \\"quoted\\" value","path":"pages/ngf/Detail"}';
      const extractResult = await ngfActionExecutorFacade.executeAction('extract', '{"path":"title"}', contextJson);
      expect(extractResult.success).assertTrue();
      const parsedExtract = JSON.parse(extractResult.outputJson) as NGFExtractActionOutputForTest;
      expect(parsedExtract.extractedValue).assertEqual('A "quoted" value');

      const navigateResult = await ngfActionExecutorFacade.executeAction(
        'navigate',
        '{"route":"pages/ngf/Detail\\\\Special","params":{"title":"A \\"quoted\\" value"}}',
        '{}'
      );
      expect(navigateResult.success).assertTrue();
      const parsedNavigate = JSON.parse(navigateResult.outputJson) as NGFNavigateActionOutputForTest;
      const intent = parsedNavigate.navigationIntent;
      expect(intent !== undefined).assertTrue();
      if (intent !== undefined) {
        expect(intent.route).assertEqual('pages/ngf/Detail\\Special');
      }
    });
  });
}

class NGFExtractActionOutputForTest {
  extractedValue?: string;
}

class NGFNavigateIntentForTest {
  route: string = '';
}

class NGFNavigateActionOutputForTest {
  navigationIntent?: NGFNavigateIntentForTest;
}

class DeterministicParallelActionExecutor implements IActionExecutor {
  readonly expectedConcurrentCount: number;
  startedCount: number = 0;
  maxConcurrentCount: number = 0;
  releasedAfterAllStarted: boolean = false;
  private readonly pendingResolvers: Array<(result: NGFActionResult) => void> = [];

  constructor(expectedConcurrentCount: number) {
    this.expectedConcurrentCount = expectedConcurrentCount;
  }

  executeAction(_actionType: string, _actionJson: string, _contextJson: string): Promise<NGFActionResult> {
    this.startedCount += 1;
    if (this.startedCount > this.maxConcurrentCount) {
      this.maxConcurrentCount = this.startedCount;
    }

    return new Promise<NGFActionResult>((resolve: (result: NGFActionResult) => void) => {
      this.pendingResolvers.push(resolve);
      if (this.startedCount === this.expectedConcurrentCount) {
        this.releasedAfterAllStarted = true;
        this.releasePendingResolvers();
      }
    });
  }

  private releasePendingResolvers(): void {
    while (this.pendingResolvers.length > 0) {
      const resolver: ((result: NGFActionResult) => void) | undefined = this.pendingResolvers.shift();
      if (resolver !== undefined) {
        resolver(new NGFActionResult(true, '{}'));
      }
    }
  }
}
