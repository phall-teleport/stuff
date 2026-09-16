// Generate floating bubbles across the whole page for the ocean theme
const bubbleContainer = document.querySelector('.bubbles');
const BUBBLE_COUNT = 24;

for (let i = 0; i < BUBBLE_COUNT; i++) {
  const bubble = document.createElement('div');
  bubble.className = 'bubble';

  const size = Math.random() * 22 + 6;
  bubble.style.width = `${size}px`;
  bubble.style.height = `${size}px`;
  bubble.style.left = `${Math.random() * 100}vw`;

  const duration = Math.random() * 14 + 10;
  bubble.style.animationDuration = `${duration}s`;
  bubble.style.animationDelay = `${Math.random() * duration}s`;

  bubbleContainer.appendChild(bubble);
}

// Smooth scroll for nav links
document.querySelectorAll('a[href^="#"]').forEach(link => {
  link.addEventListener('click', e => {
    const target = document.querySelector(link.getAttribute('href'));
    if (target) {
      e.preventDefault();
      target.scrollIntoView({ behavior: 'smooth' });
    }
  });
});
