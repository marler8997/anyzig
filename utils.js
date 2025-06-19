function showNotification(message, isError = false) {
  const notification = document.createElement("div");
  notification.textContent = message;
  notification.style.cssText = `
      position: fixed;
      top: 20px;
      right: 20px;
      padding: 10px 20px;
      border-radius: 4px;
      background-color: ${isError ? "#ff4444" : "#44ff44"};
      color: white;
      z-index: 1000;
    `;
  document.body.appendChild(notification);
  setTimeout(() => notification.remove(), 3000);
}
