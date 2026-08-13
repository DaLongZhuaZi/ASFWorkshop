import { SteamArkLog } from '../../steamServices/SteamArkLogger';

/**
 * The root HdsNavigation owns the only usable NavPathStack. Keep the native
 * object outside V1 component properties so ArkUI does not clone its handle.
 */
export class SteamArkNavigationBridge {
  private static homeStack: NavPathStack | null = null;
  private static readonly homeStackReadyListeners: Map<string, () => void> = new Map<string, () => void>();

  static bindHomeStack(stack: NavPathStack): void {
    SteamArkNavigationBridge.homeStack = stack;
    SteamArkLog.debug('NavigationBridge', 'home navigation stack bound');
    SteamArkNavigationBridge.notifyHomeStackReady();
  }

  static unbindHomeStack(stack: NavPathStack): void {
    if (SteamArkNavigationBridge.homeStack === stack) {
      SteamArkNavigationBridge.homeStack = null;
      SteamArkLog.debug('NavigationBridge', 'home navigation stack unbound');
    }
  }

  static onHomeStackReady(listenerId: string, listener: () => void): void {
    SteamArkNavigationBridge.homeStackReadyListeners.set(listenerId, listener);
    if (SteamArkNavigationBridge.homeStack !== null) {
      SteamArkNavigationBridge.notifyHomeStackReadyListener(listenerId, listener);
    }
  }

  static offHomeStackReady(listenerId: string): void {
    SteamArkNavigationBridge.homeStackReadyListeners.delete(listenerId);
  }

  static pushHomeRoute(routeName: string, param: Object | null = null): boolean {
    const stack: NavPathStack | null = SteamArkNavigationBridge.homeStack;
    if (stack === null) {
      SteamArkLog.warn('NavigationBridge', 'route push skipped; home stack is not bound, route=' + routeName);
      return false;
    }

    try {
      stack.pushPathByName(routeName, param);
      SteamArkLog.info('NavigationBridge', 'route pushed; route=' + routeName);
      return true;
    } catch (error) {
      SteamArkLog.error('NavigationBridge', 'route push failed; route=' + routeName);
      return false;
    }
  }

  private static notifyHomeStackReady(): void {
    const listeners: Map<string, () => void> = new Map<string, () => void>();
    SteamArkNavigationBridge.homeStackReadyListeners.forEach((listener: () => void, listenerId: string): void => {
      listeners.set(listenerId, listener);
    });
    listeners.forEach((listener: () => void, listenerId: string): void => {
      SteamArkNavigationBridge.notifyHomeStackReadyListener(listenerId, listener);
    });
  }

  private static notifyHomeStackReadyListener(listenerId: string, listener: () => void): void {
    try {
      listener();
    } catch (error) {
      SteamArkLog.warn('NavigationBridge', 'home navigation readiness listener failed; listener=' + listenerId +
        ', errorType=' + SteamArkLog.errorKind(error));
    }
  }
}
