/* global axios */
import ApiClient from './ApiClient';

class StickersAPI extends ApiClient {
  constructor() {
    super('stickers', { accountScoped: true });
  }

  // Envia uma figurinha da biblioteca como mensagem na conversa (endpoint dedicado).
  sendToConversation(conversationId, stickerId) {
    return axios.post(
      `${this.baseUrl()}/conversations/${conversationId}/sticker_messages`,
      { sticker_id: stickerId }
    );
  }
}

export default new StickersAPI();
