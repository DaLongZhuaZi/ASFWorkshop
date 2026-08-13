export enum NGFNotificationType {
  BASIC = 0,
  LONG_TEXT = 1,
  MULTILINE = 2,
  PICTURE = 3,
  PROGRESS = 4,
  CUSTOM = 5
}

export enum NGFNotificationSlotType {
  OTHER = 0,
  SOCIAL_COMMUNICATION = 1,
  SERVICE_INFORMATION = 2,
  CONTENT_INFORMATION = 3,
  CUSTOMER_SERVICE = 4
}

export class NGFNotificationRequest {
  id: number;
  title: string;
  content: string;
  type: NGFNotificationType;
  
  progressValue: number;
  progressMax: number;
  isOngoing: boolean;
  slotType: NGFNotificationSlotType;

  // 扩展属性
  longText?: string;
  lines?: Array<string>;
  templateName?: string;
  templateData?: Record<string, Object>;
  /** Optional parameters delivered to this app's UIAbility when the notification is tapped. */
  wantParameters?: Record<string, Object>;
  
  constructor(
    id: number, 
    title: string, 
    content: string, 
    type: NGFNotificationType = NGFNotificationType.BASIC,
    progressValue: number = 0, 
    progressMax: number = 0, 
    isOngoing: boolean = false,
    slotType: NGFNotificationSlotType = NGFNotificationSlotType.OTHER
  ) {
    this.id = id;
    this.title = title;
    this.content = content;
    this.type = type;
    this.progressValue = progressValue;
    this.progressMax = progressMax;
    this.isOngoing = isOngoing;
    this.slotType = slotType;
  }
}

export interface ISystemNotificationManager {
  requestPermission(): Promise<boolean>;
  publish(request: NGFNotificationRequest): Promise<void>;
  cancel(id: number): Promise<void>;
}
