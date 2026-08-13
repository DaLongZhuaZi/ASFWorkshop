import { describe, beforeEach, it, expect } from '@ohos/hypium';
import {
  NGFEventPayload,
  NGFTaskExecutor,
  ngfSystem
} from 'ngf_framework';

export default function systemIntegrationTest() {
  describe('SystemIntegrationFacadeTest', () => {
    const taskName: string = 'unit.system.task';
    const eventName: string = 'unit.system.event';
    const listenerId: string = 'unit.system.listener';

    beforeEach(() => {
      ngfSystem.unsubscribeSystemEvent(eventName, listenerId);
    });

    it('testSubmitTaskLifecycle', 0, async () => {
      const executor: NGFTaskExecutor = async (
        taskId: string,
        updateCallback: (progress: number, total: number, message: string) => void
      ): Promise<void> => {
        updateCallback(100, 100, 'Completed ' + taskId);
      };

      const taskId = await ngfSystem.submitTask(taskName, executor);
      const task = ngfSystem.getTask(taskId);
      expect(task !== null).assertTrue();
      if (task !== null) {
        expect(task.name).assertEqual(taskName);
      }
    });

    it('testSystemEventSubscriptionLifecycle', 0, () => {
      const received: Array<string> = [];
      const listener = (payload: NGFEventPayload): void => {
        received.push(payload.payloadJson);
      };

      expect(ngfSystem.subscribeSystemEvent(eventName, listenerId, listener)).assertTrue();
      ngfSystem.publishSystemEvent(eventName, new NGFEventPayload('unit', '{"ok":true}', Date.now()));
      expect(received.length).assertEqual(1);
      expect(received[0]).assertEqual('{"ok":true}');
      expect(ngfSystem.unsubscribeSystemEvent(eventName, listenerId)).assertTrue();
      ngfSystem.publishSystemEvent(eventName, new NGFEventPayload('unit', '{"ignored":true}', Date.now()));
      expect(received.length).assertEqual(1);
    });
  });
}
