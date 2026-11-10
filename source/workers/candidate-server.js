const {createGalleryServer} = require('../helper/gallery-helper');
const server=createGalleryServer();
server.listen(9337,'127.0.0.1',()=>console.log('Candidate gallery: http://127.0.0.1:9337'));
