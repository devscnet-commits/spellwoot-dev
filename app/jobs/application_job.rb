class ApplicationJob < ActiveJob::Base
  # RequestStore é escopado a UMA requisição HTTP: o middleware do gem (inserido pelo railtie) abre e
  # limpa o store a cada request. Em Sidekiq esse middleware NÃO existe — nenhum initializer o
  # instala — então o store vive enquanto a THREAD do worker viver, e tudo que memoiza ali passa a
  # devolver dado velho por tempo indeterminado. O FeatureGate memoiza o plano da conta exatamente
  # assim: sem este clear, trocar o plano de um cliente só teria efeito nos jobs depois de um
  # restart do worker.
  #
  # Só age FORA de uma requisição: um perform_now chamado de dentro de um controller compartilha o
  # store com a requisição (o lograge escreve ali), e limpá-lo no meio dela apagaria dado alheio.
  around_perform do |_job, block|
    if defined?(RequestStore) && !RequestStore.active?
      RequestStore.clear!
      begin
        block.call
      ensure
        RequestStore.clear!
      end
    else
      block.call
    end
  end

  # https://api.rubyonrails.org/v5.2.1/classes/ActiveJob/Exceptions/ClassMethods.html
  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.info("Skipping #{job.class} with #{
      job.instance_variable_get(:@serialized_arguments)
    } because of ActiveJob::DeserializationError (#{error.message})")
  end
end
