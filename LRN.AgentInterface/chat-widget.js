(function () {
  'use strict';

  document.addEventListener('DOMContentLoaded', function () {
    var widget = document.querySelector('.reimb-chat-widget');
    if (!widget) {
      return;
    }

    var apiUrl = widget.getAttribute('data-agent-api-url');
    var bubble = document.getElementById('reimbChatBubble');
    var panel = document.getElementById('reimbChatPanel');
    var closeBtn = document.getElementById('reimbChatClose');
    var messagesEl = document.getElementById('reimbChatMessages');
    var input = document.getElementById('reimbChatInput');
    var sendBtn = document.getElementById('reimbChatSend');

    var isSending = false;
    var cachedToken = null;
    var cachedTokenExpiresAt = 0;

    // Fetches a short-lived sign-in ticket from this SAME site (same-origin,
    // so the browser sends the existing login cookie automatically) and
    // caches it until shortly before it expires.
    function getChatToken() {
      var now = Date.now();
      if (cachedToken && now < cachedTokenExpiresAt) {
        return Promise.resolve(cachedToken);
      }

      return fetch('/api/chat-token', { credentials: 'same-origin' })
        .then(function (response) {
          if (!response.ok) {
            throw new Error('Not signed in');
          }
          return response.json();
        })
        .then(function (data) {
          cachedToken = data.token;
          // Refresh a minute early so a question in flight never gets
          // caught by the token expiring mid-request.
          cachedTokenExpiresAt = now + (data.expiresInSeconds - 60) * 1000;
          return cachedToken;
        });
    }

    function appendMessage(role, text) {
      var el = document.createElement('div');
      el.className = 'reimb-chat-message reimb-chat-message-' + role;
      el.textContent = text;
      messagesEl.appendChild(el);
      messagesEl.scrollTop = messagesEl.scrollHeight;
      return el;
    }

    function setOpen(open) {
      panel.hidden = !open;
      bubble.setAttribute('aria-label', open ? 'Close reimbursement chat' : 'Open reimbursement chat');
      bubble.innerHTML = open ? '&times;' : '&#128172;';
      if (open) {
        input.focus();
      }
    }

    bubble.addEventListener('click', function () {
      setOpen(panel.hidden);
    });

    if (closeBtn) {
      closeBtn.addEventListener('click', function () {
        setOpen(false);
      });
    }

    function sendMessage() {
      var question = input.value.trim();
      if (!question || isSending) {
        return;
      }

      appendMessage('user', question);
      input.value = '';
      isSending = true;
      sendBtn.disabled = true;

      var typingEl = appendMessage('agent', 'Looking that up…');
      typingEl.classList.add('reimb-chat-typing');

      getChatToken()
        .then(function (token) {
          return fetch(apiUrl, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              Authorization: 'Bearer ' + token
            },
            body: JSON.stringify({ question: question })
          });
        })
        .then(function (response) {
          if (!response.ok) {
            throw new Error('Request failed with status ' + response.status);
          }
          return response.json();
        })
        .then(function (data) {
          typingEl.remove();
          appendMessage('agent', data.answer || 'No response was returned.');
        })
        .catch(function () {
          typingEl.remove();
          appendMessage(
            'agent',
            'Sorry, something went wrong reaching the reimbursement agent. Please try again.'
          );
        })
        .finally(function () {
          isSending = false;
          sendBtn.disabled = false;
        });
    }

    sendBtn.addEventListener('click', sendMessage);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
      }
    });
  });
})();
