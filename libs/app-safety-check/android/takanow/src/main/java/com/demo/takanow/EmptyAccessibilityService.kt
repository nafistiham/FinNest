package com.demo.takanow

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Deliberately empty accessibility service. It receives only `typeViewClicked` events (see
 * res/xml/accessibility_service_config.xml), never inspects them, never calls
 * `getRootInActiveWindow()`, `performGlobalAction()` or `dispatchGesture()`, and holds no state.
 * Its only purpose is to make the OS report an enabled accessibility service for this package
 * so the FinNest App Safety Check can demonstrate the SIDELOADED_ACCESSIBILITY finding.
 */
class EmptyAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Intentionally empty: reads nothing, stores nothing, sends nothing.
    }

    override fun onInterrupt() {
        // Intentionally empty.
    }
}
