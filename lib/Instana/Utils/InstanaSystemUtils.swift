//  Created by Nikola Lajic on 1/25/19.
//  Copyright © 2019 Nikola Lajic. All rights reserved.

import Foundation

class InstanaSystemUtils {
    /// Returns device model (for ex. "iPhone10,1")
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
    
    /// Returns iOS version (for ex. "12.1")
    static var systemVersion: String {
        return UIDevice.current.systemVersion
    }
    
    /// Returns application version (for ex. "1.1")
    static var applicationVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown-version"
    }
    
    /// Returns application build number (for ex. "123")
    static var applicationBuildNumber: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unkown-build-number"
    }
    
    /// Returns a ' > ' sepparated string of view controller class names in the app hierarchy.
    /// This is only a superficial check, and doesn't go deeper than one level.
    static func viewControllersHierarchy() -> String? {
        guard let root = UIApplication.shared.delegate?.window??.rootViewController else { return nil }
        var vcs: [UIViewController] = []
        let rootName = String(describing: type(of: root))
        
        switch root {
        case let nvc as UINavigationController:
            vcs.append(contentsOf: nvc.viewControllers)
        case let tvc as UITabBarController:
            if let selected = tvc.selectedViewController {
                vcs.append(selected)
            }
        case let svc as UISplitViewController:
            vcs.append(contentsOf: svc.viewControllers)
        default:
            break
        }
        
        if let modal = (vcs.last ?? root).presentedViewController {
            vcs.append(modal)
        }
        
        return vcs
            .map { String(describing: type(of: $0)) }
            .reduce(rootName) { "\($0) > \($1)" }
    }
}
