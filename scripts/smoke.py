import argparse
import json
import secrets
import sys
import uuid
from urllib.parse import urlsplit

import requests
from selenium import webdriver
from selenium.common.exceptions import WebDriverException
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import Select, WebDriverWait


def run(base, headed, timeout):
    username = "smoke_" + uuid.uuid4().hex[:24]  
    email, password = username + "@example.invalid", "Sm0ke!" + secrets.token_urlsafe(24)
    credentials = {"username": username, "password": password}
    driver, attempted, deleted, stage = None, False, False, "browser startup"

    def api(method, path, **kwargs):
        
        return requests.request(method, base + path, timeout=timeout, allow_redirects=False, **kwargs)

    def field(name, value):
        element = wait.until(EC.visibility_of_element_located((By.CSS_SELECTOR, f'[formcontrolname="{name}"]')))
        element.clear()
        element.send_keys(value)

    def click(selector):
        element = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, selector)))
        driver.get_log("performance") 
        element.click()

    def response(path, status, read_json=False):
        received = {}

        def completed(browser):
            for entry in browser.get_log("performance"):
                message = json.loads(entry["message"])["message"]
                if message["method"] == "Network.responseReceived":
                    params = message["params"]
                    if params["response"]["url"] == base + path:
                        received.update(params)
            if not received:
                return False
            actual = received["response"]["status"]
            assert actual == status, f"{path}: HTTP {actual}, expected {status}"
            if not read_json:
                return True
            try:
                body = browser.execute_cdp_cmd("Network.getResponseBody", {"requestId": received["requestId"]})
            except WebDriverException:
                return False 
            return json.loads(body["body"])

        return wait.until(completed)

    try:
        options = webdriver.ChromeOptions()
        if not headed:
            options.add_argument("--headless=new")
        options.add_argument("--window-size=1440,1000")
        options.set_capability("goog:loggingPrefs", {"performance": "ALL"})
        driver = webdriver.Chrome(options=options)
        driver.set_page_load_timeout(timeout)
        wait = WebDriverWait(driver, timeout)

        stage = "registration"
        driver.get(base + "/register")
        for name, value in dict(username=username, email=email, password=password,
                                firstName="Smoke", lastName="Test", address="Smoke test").items():
            field(name, value)
        Select(driver.find_element(By.CSS_SELECTOR, '[formcontrolname="role"]')).select_by_visible_text("Guest")
        attempted = True
        click("app-register form button.btn-success")
        response("/api/auth/register", 201)
        wait.until(EC.url_to_be(base + "/login"))

        stage = "login and profile"
        field("username", username)
        field("password", password)
        click("app-login form button.btn-primary")
        response("/api/auth/login", 200)
        wait.until(EC.url_to_be(base + "/accommodations"))
        driver.get(base + "/users/profile")
        wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '[formcontrolname="username"]').get_attribute("value") == username)
        assert driver.find_element(By.CSS_SELECTOR, '[formcontrolname="email"]').get_attribute("value") == email

        stage = "empty search through the frontend"
        driver.get(base + "/accommodations")
        field("city", "no_city_" + uuid.uuid4().hex)
        click('app-accommodations-list button[type="submit"]')
        result = response("/api/search", 200, read_json=True)
        assert result["items"] == [] and result["totalCount"] == 0, "Expected an empty search response"
        wait.until(EC.text_to_be_present_in_element(
            (By.CSS_SELECTOR, "app-accommodations-list .alert-info"),
            "No accommodations found for the selected criteria."))
        assert not driver.find_elements(By.CSS_SELECTOR, "app-accommodations-list tbody tr")

        stage = "delete account through the frontend"
        driver.get(base + "/users/profile")
        wait.until(lambda d: d.find_element(By.CSS_SELECTOR, '[formcontrolname="username"]').get_attribute("value") == username)
        click("app-profile .btn-delete")
        click("#deleteAccountModal .modal-footer .btn-danger")
        response("/api/auth", 204)
        wait.until(EC.url_to_be(base + "/login"))

        stage = "login rejected after deletion"
        field("username", username)
        field("password", password)
        click("app-login form button.btn-primary")
        response("/api/auth/login", 401)
        wait.until(EC.visibility_of_element_located((By.CSS_SELECTOR, ".mat-mdc-snack-bar-container")))
        assert driver.current_url == base + "/login"
        assert not driver.execute_script("return localStorage.getItem('auth_token')")
        deleted = True
        print("Smoke passed: browser registration, login, profile, empty search and deletion.")
        return 0
    except Exception as error:
        detail = str(error) if isinstance(error, AssertionError) else type(error).__name__
        print(f"Smoke FAILED at {stage}: {detail}", file=sys.stderr)
        return 1
    finally:
        if attempted and not deleted:
            try:
                login = api("POST", "/api/auth/login", json=credentials)
                assert login.status_code == 200
                headers = {"Authorization": "Bearer " + login.json()["token"]}
                profile_response = api("GET", "/api/auth/profile", headers=headers)
                assert profile_response.status_code == 200
                profile = profile_response.json()
                assert (profile["username"], profile["email"], profile["role"]) == (username, email, "Guest")
                assert api("DELETE", "/api/auth", headers=headers).status_code == 204
                assert api("POST", "/api/auth/login", json=credentials).status_code == 401
                print("Fallback cleanup: test guest deleted.")
            except Exception:
                print(f"Cleanup NOT confirmed; check only test account {username} ({email}).", file=sys.stderr)
        if driver:
            driver.quit()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Browser smoke: register, log in, search an empty city, delete the guest.")
    parser.add_argument("base_url", help="Application origin, e.g. http://booking.local")
    parser.add_argument("--headed", action="store_true", help="Show the browser window")
    parser.add_argument("--timeout", type=int, default=30, help="Seconds per wait/request")
    args = parser.parse_args()
    url = urlsplit(args.base_url)
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.path not in ("", "/") or url.query or url.fragment:
        parser.error("Use an HTTP(S) origin without credentials, path, query or fragment")
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    sys.exit(run(args.base_url.rstrip("/"), args.headed, args.timeout))
