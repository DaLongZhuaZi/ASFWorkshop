import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { uiContextManager } from '../../platformOhos/UIContextManager';
import {
  ISystemNotificationManager,
  NGFNotificationRequest,
  NGFNotificationSlotType,
  NGFNotificationType
} from '../contracts/ISystemNotificationManager';
import { logger } from '../../utils/Logger';

const TAG: string = 'SystemNotificationManagerFacade';

class SystemNotificationManagerFacade implements ISystemNotificationManager {
  private readonly registeredSlots: Array<NGFNotificationSlotType> = [];
  private readonly slotRegistrationTasks: Map<NGFNotificationSlotType, Promise<void>> =
    new Map<NGFNotificationSlotType, Promise<void>>();

  async requestPermission(): Promise<boolean> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        logger.debug(TAG, '通知权限已启用');
        return true;
      }
      const context = uiContextManager.getFullAbilityContext();
      if (!context) {
        logger.warn(TAG, '无 UIAbilityContext，无法申请通知权限');
        return false;
      }
      await notificationManager.requestEnableNotification(context);
      logger.info(TAG, '通知权限申请完成');
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      logger.error(TAG, '申请通知权限失败: ' + e);
      return false;
    }
  }

  async publish(request: NGFNotificationRequest): Promise<void> {
    try {
      let notificationContent: notificationManager.NotificationContent;
      const slotType: notificationManager.SlotType = await this.ensureSlot(request.slotType);

      switch (request.type) {
        case NGFNotificationType.LONG_TEXT:
          notificationContent = {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
            longText: {
              title: request.title,
              text: request.content,
              longText: request.longText || request.content,
              briefText: request.content,
              expandedTitle: request.title
            }
          };
          break;
        case NGFNotificationType.MULTILINE:
          notificationContent = {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
            multiLine: {
              title: request.title,
              text: request.content,
              briefText: request.content,
              longTitle: request.title,
              lines: request.lines || [request.content]
            }
          };
          break;
        // PICTURE can be handled similarly if needed, defaulting to basic for now if no picture is provided
        case NGFNotificationType.BASIC:
        case NGFNotificationType.PROGRESS:
        case NGFNotificationType.CUSTOM:
        default:
          let displayText = request.content;
          if (request.type === NGFNotificationType.BASIC && request.progressMax > 0) {
            const percentage = Math.floor((request.progressValue / request.progressMax) * 100);
            displayText += ' [' + percentage + '%]';
          }
          notificationContent = {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: request.title,
              text: displayText
            }
          };
          break;
      }

      const req: notificationManager.NotificationRequest = {
        id: request.id,
        content: notificationContent,
        isOngoing: request.isOngoing,
        notificationSlotType: slotType
      };
      const clickWantAgent: WantAgent | null = await this.createClickWantAgent(request);
      if (clickWantAgent !== null) {
        req.wantAgent = clickWantAgent;
        req.tapDismissed = true;
      }

      if (request.type === NGFNotificationType.PROGRESS) {
        let defaultData: Record<string, Object> = {
          'title': request.title as Object,
          'fileName': request.content as Object,
          'progressValue': request.progressValue as Object,
          'progressMaxValue': request.progressMax as Object,
          'isProgressIndeterminate': (request.progressMax <= 0) as Object
        };

        req.template = {
          name: request.templateName || 'downloadTemplate',
          data: request.templateData || defaultData
        };
      } else if (request.type === NGFNotificationType.CUSTOM && request.templateName) {
        let emptyData: Record<string, Object> = {};
        req.template = {
          name: request.templateName,
          data: request.templateData || emptyData
        };
      }

      await notificationManager.publish(req);
      logger.debug(TAG, '发送通知成功: ID=' + request.id + ', 类型=' + request.type);
    } catch (e) {
      const error: Error = e instanceof Error ? e : new Error(String(e));
      logger.error(TAG, '发送通知失败: ' + error.message);
      throw error;
    }
  }

  async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
      logger.debug(TAG, '取消通知成功: ID=' + id);
    } catch (e) {
      logger.error(TAG, '取消通知失败: ' + e);
    }
  }

  private async createClickWantAgent(request: NGFNotificationRequest): Promise<WantAgent | null> {
    const parameters: Record<string, Object> | undefined = request.wantParameters;
    if (parameters === undefined) {
      return null;
    }
    const context = uiContextManager.getFullAbilityContext();
    if (context === null) {
      logger.warn(TAG, '通知点击目标不可用，缺少 UIAbilityContext: ID=' + request.id.toString());
      return null;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
          parameters: parameters
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: request.id,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      logger.warn(TAG, '通知点击目标创建失败: ID=' + request.id.toString());
      return null;
    }
  }

  private async ensureSlot(slotType: NGFNotificationSlotType): Promise<notificationManager.SlotType> {
    const platformSlotType: notificationManager.SlotType = this.toPlatformSlotType(slotType);
    if (slotType === NGFNotificationSlotType.OTHER || this.registeredSlots.includes(slotType)) {
      return platformSlotType;
    }
    const currentTask: Promise<void> | undefined = this.slotRegistrationTasks.get(slotType);
    if (currentTask !== undefined) {
      await currentTask;
    } else {
      const registrationTask: Promise<void> = notificationManager.addSlot(platformSlotType);
      this.slotRegistrationTasks.set(slotType, registrationTask);
      try {
        await registrationTask;
      } finally {
        this.slotRegistrationTasks.delete(slotType);
      }
    }
    if (!this.registeredSlots.includes(slotType)) {
      this.registeredSlots.push(slotType);
      logger.debug(TAG, '通知槽已注册: 类型=' + slotType.toString());
    }
    return platformSlotType;
  }

  private toPlatformSlotType(slotType: NGFNotificationSlotType): notificationManager.SlotType {
    switch (slotType) {
      case NGFNotificationSlotType.SOCIAL_COMMUNICATION:
        return notificationManager.SlotType.SOCIAL_COMMUNICATION;
      case NGFNotificationSlotType.SERVICE_INFORMATION:
        return notificationManager.SlotType.SERVICE_INFORMATION;
      case NGFNotificationSlotType.CONTENT_INFORMATION:
        return notificationManager.SlotType.CONTENT_INFORMATION;
      case NGFNotificationSlotType.CUSTOMER_SERVICE:
        return notificationManager.SlotType.CUSTOMER_SERVICE;
      case NGFNotificationSlotType.OTHER:
      default:
        return notificationManager.SlotType.OTHER_TYPES;
    }
  }
}

export const ngfSystemNotificationManager: ISystemNotificationManager = new SystemNotificationManagerFacade();
