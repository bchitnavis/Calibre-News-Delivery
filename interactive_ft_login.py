import sys
import json
from playwright.sync_api import sync_playwright

def main():
    print("Launching browser...")
    with sync_playwright() as p:
        browser = p.firefox.launch(headless=False)
        context = browser.new_context(user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0')
        page = context.new_page()
        
        print("Navigating to FT Login...")
        page.goto("https://accounts.ft.com/login?location=https%3A%2F%2Fsubs.ft.com%2Fspa3_sfepaper_3M20")
        
        print("\n" + "="*60)
        print("BROWSER IS OPEN ON YOUR SCREEN.")
        print("Please log in manually, solve any CAPTCHAs, and ensure you reach the logged-in state.")
        print("="*60)
        
        # Wait for user input from standard input
        input("PRESS ENTER HERE (or tell the AI to press Enter) when you are fully logged in: ")
        
        print("Extracting cookies...")
        cookies = context.cookies()
        cookie_string = "; ".join([f"{c['name']}={c['value']}" for c in cookies])
        
        config_path = "standalone.config.json"
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
            
        config["ftAuth"]["cookieHeader"] = cookie_string
        config["ftAuth"]["username"] = ""
        config["ftAuth"]["password"] = ""
        
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=4)
            
        print("Cookies successfully saved to standalone.config.json!")
        browser.close()

if __name__ == "__main__":
    main()
