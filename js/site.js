/* Chuchu Rosa — comportamento do header único (.site-nav)
   Menu hambúrguer, busca no celular, contador do carrinho e sombra ao rolar. */
(function(){
  var nav=document.getElementById('siteNav');
  if(!nav)return;

  // ── link da página atual ──
  var page=nav.getAttribute('data-page');
  if(page){
    document.querySelectorAll('[data-nav="'+page+'"]').forEach(function(a){a.setAttribute('aria-current','page');});
  }

  // ── sombra ao rolar ──
  var queued=false;
  function onScroll(){queued=false;nav.classList.toggle('is-scrolled',window.scrollY>8);}
  window.addEventListener('scroll',function(){if(!queued){queued=true;requestAnimationFrame(onScroll);}},{passive:true});
  onScroll();

  // ── menu hambúrguer ──
  var burger=document.getElementById('snBurger');
  var drawer=document.getElementById('snDrawer');
  var scrim=document.getElementById('snScrim');
  function isOpen(){return burger&&burger.getAttribute('aria-expanded')==='true';}
  function openMenu(){
    closeSearch();
    drawer.hidden=false;scrim.hidden=false;
    requestAnimationFrame(function(){drawer.classList.add('open');scrim.classList.add('open');});
    burger.setAttribute('aria-expanded','true');burger.setAttribute('aria-label','Fechar menu');
    var first=drawer.querySelector('a,button');if(first)first.focus({preventScroll:true});
  }
  function closeMenu(returnFocus){
    if(!isOpen())return;
    drawer.classList.remove('open');scrim.classList.remove('open');
    burger.setAttribute('aria-expanded','false');burger.setAttribute('aria-label','Abrir menu');
    setTimeout(function(){if(!drawer.classList.contains('open')){drawer.hidden=true;scrim.hidden=true;}},260);
    if(returnFocus)burger.focus();
  }
  if(burger&&drawer&&scrim){
    burger.addEventListener('click',function(){isOpen()?closeMenu(false):openMenu();});
    scrim.addEventListener('click',function(){closeMenu(false);});
    drawer.addEventListener('click',function(e){if(e.target.closest('a'))closeMenu(false);});
  }

  // ── busca no celular (loja) ──
  var searchBtn=document.getElementById('snSearchBtn');
  var searchInput=nav.querySelector('.sn-search input');
  function openSearch(){
    if(!searchInput)return;
    nav.classList.add('search-open');
    if(searchBtn)searchBtn.setAttribute('aria-expanded','true');
    searchInput.focus();
  }
  function closeSearch(){
    if(!nav.classList.contains('search-open'))return;
    nav.classList.remove('search-open');
    if(searchBtn)searchBtn.setAttribute('aria-expanded','false');
  }
  if(searchBtn)searchBtn.addEventListener('click',function(){
    if(nav.classList.contains('search-open')){closeSearch();searchBtn.focus();}else{closeMenu(false);openSearch();}
  });

  document.addEventListener('keydown',function(e){
    if(e.key!=='Escape')return;
    if(isOpen())closeMenu(true);
    else if(nav.classList.contains('search-open')){closeSearch();if(searchBtn)searchBtn.focus();}
  });

  // ── contador do carrinho (páginas sem carrinho próprio) ──
  function cartQty(){
    try{
      var c=JSON.parse(localStorage.getItem('cr_cart')||'[]');
      if(c&&!Array.isArray(c)){if(c.exp&&Date.now()>c.exp)return 0;c=c.data;}
      if(!Array.isArray(c))return 0;
      return c.reduce(function(s,i){return s+(+(i.qty||i.quantidade||1));},0);
    }catch(e){return 0;}
  }
  function paintCount(){
    var n=cartQty();
    document.querySelectorAll('[data-cart-count]').forEach(function(el){
      el.textContent=n>0?n:'';
    });
  }
  paintCount();
  window.addEventListener('storage',function(e){if(e.key==='cr_cart')paintCount();});

  // ── ano atual no rodapé ──
  document.querySelectorAll('[data-ano-atual]').forEach(function(el){el.textContent=new Date().getFullYear();});

  // ── links vindos de outras páginas: loja.html?buscar=1 / ?carrinho=1 ──
  var params=new URLSearchParams(location.search);
  if(params.has('buscar')&&searchInput){
    window.addEventListener('load',function(){
      if(window.matchMedia('(max-width:768px)').matches)openSearch();else searchInput.focus();
    });
  }
  if(params.has('carrinho')){
    window.addEventListener('load',function(){
      if(typeof window.openCart==='function')window.openCart();
      else if(typeof window.openCartDrawer==='function')window.openCartDrawer();
    });
  }
})();
