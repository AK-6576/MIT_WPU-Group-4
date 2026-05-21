//
//  SceneDelegate.swift
//  ANSD_APP
//
//  Created by Dhiraj Bodake on 15/12/25.
//  Copyright © 2025 MIT-WPU Group 4. All rights reserved.
//

import UIKit
import FirebaseAuth

// MARK: - Scene Delegate
// Manages the application's scene lifecycle, handling session connections and state transitions.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // --- Persistence Logic ---
        // Check if a user is already authenticated via Firebase.
        if Auth.auth().currentUser != nil {
            // User is logged in: Navigate directly to the Home screen.
            let storyboard = UIStoryboard(name: "Home", bundle: nil)
            if let homeNav = storyboard.instantiateViewController(withIdentifier: "HomeNav") as? UINavigationController {
                let window = UIWindow(windowScene: windowScene)
                window.rootViewController = homeNav
                self.window = window
                window.makeKeyAndVisible()
                print("SceneDelegate: Active session found. Routing to Home.")
            }
        } else {
            // No user logged in: Default to the Onboarding entry point (Welcome Screen).
            print("SceneDelegate: No active session. Routing to Onboarding.")
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}
